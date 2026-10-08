# frozen_string_literal: true

require "utils/github"
require "digest"
require "time"
require "uri"
require "set"
require_relative "registry"
require_relative "build_order"
require_relative "../policy"
require_relative "../executor/tap_candidate"

module BrewCooldown
  module HomebrewAdapter
    TapHistoryEntry = Data.define(:commit, :published_at)

    # Configured trust names the conventional GitHub tap repository. The
    # default-branch head bounds historical recipes without mutating local taps.
    class TapHistory
      attr_reader :package, :head, :path, :current

      def initialize(package:, log:, now:, request: GitHub::API.method(:open_rest))
        @package, @log, @now, @request = package, log, now, request
        owner, tap = package.tap.split("/")
        @repository = "#{owner}/homebrew-#{tap}"
        @api = "https://api.github.com/repos/#{@repository}"
      end

      def refresh
        repository = request(@api)
        unless repository.is_a?(Hash) && repository.fetch("full_name").downcase == @repository &&
               repository["default_branch"].is_a?(String) && !repository["default_branch"].empty?
          raise RegistryError, "Trusted tap repository identity differs: #{@repository}"
        end
        branch = URI.encode_www_form_component(repository.fetch("default_branch"))
        @head = commit!(request("#{@api}/commits/#{branch}").fetch("sha"))
        tree = request("#{@api}/git/trees/#{head}?recursive=1")
        unless tree.is_a?(Hash) && tree["truncated"] == false && tree["tree"].is_a?(Array)
          raise RegistryError, "Trusted tap tree is incomplete: #{@repository}"
        end
        paths = tree.fetch("tree").select do |row|
          row.is_a?(Hash) && row["type"] == "blob" && row["mode"] == "100644" &&
            row["path"].is_a?(String) && row["path"].start_with?("Formula/") &&
            File.basename(row["path"]) == "#{package.name}.rb"
        end
        raise RegistryError, "Missing or ambiguous trusted formula path: #{package.name}" unless paths.length == 1

        @path = paths.first.fetch("path")
        @current = candidate(TapHistoryEntry.new(commit: head, published_at: nil))
        verify_current!
        self
      end

      def entries
        Enumerator.new do |results|
          seen = Set.new
          page = 1
          loop do
            query = URI.encode_www_form(path:, sha: head, per_page: 100, page:)
            rows = request("#{@api}/commits?#{query}")
            raise RegistryError, "Invalid trusted tap history page" unless rows.is_a?(Array)
            raise RegistryError, "Trusted formula history is empty" if page == 1 && rows.empty?

            rows.each do |row|
              commit = commit!(row.fetch("sha"))
              raise RegistryError, "Repeated trusted tap commit" unless seen.add?(commit)

              results << TapHistoryEntry.new(commit:, published_at: publication_time(row.dig("commit", "committer", "date")))
            end
            break if rows.length < 100

            page += 1
          end
        end
      end

      def source_record(entry)
        content = request("#{@api}/contents/#{path}?ref=#{entry.commit}")
        unless content.is_a?(Hash) && content["type"] == "file" && content["path"] == path &&
               content["encoding"] == "base64" && content["content"].is_a?(String)
          raise RegistryError, "Historical trusted formula source is unavailable: #{entry.commit}"
        end
        bytes = content.fetch("content").delete("\n").unpack1("m0")
        blob = Digest::SHA1.hexdigest("blob #{bytes.bytesize}\0" + bytes)
        raise RegistryError, "Historical trusted source blob differs" unless content["sha"] == blob

        { "name" => package.name, "tap" => package.tap, "repository" => @repository,
          "commit" => entry.commit, "source_path" => path, "source_sha256" => Digest::SHA256.hexdigest(bytes) }
      end

      def candidate(entry)
        Executor::TapCandidate.new(source_record(entry)).load_recipe
      end

      def verify_candidate!(candidate)
        verify_current!
        if BuildOrder.call(candidate.build, current.build).positive?
          raise RegistryError, "#{package.name}: historical release is ahead of current trusted tap build; possible rollback"
        end
      end

      def publication(candidate, entry)
        uri = URI(candidate.formula.resource.url)
        pieces = uri.path.split("/")
        owner, repository, tag = pieces.values_at(1, 2, 5)
        release = request("https://api.github.com/repos/#{owner}/#{repository}/releases/tags/#{URI.encode_www_form_component(tag)}")
        unless release.is_a?(Hash) && release["tag_name"] == tag && release["draft"] == false && release["assets"].is_a?(Array)
          raise RegistryError, "Release identity is unavailable: #{candidate.formula.resource.url}"
        end
        assets = release.fetch("assets").select { |asset| asset.is_a?(Hash) && asset["browser_download_url"] == uri.to_s }
        raise RegistryError, "Release archive is missing or ambiguous: #{uri}" unless assets.length == 1

        asset = assets.first
        digest = asset["digest"]
        expected = "sha256:#{candidate.formula.resource.checksum.hexdigest}"
        raise RegistryError, "Vendor archive digest differs from trusted recipe: #{uri}" if digest && digest != expected

        # Git commit time alone cannot age a replaced vendor asset. Missing
        # dates restart the conservative, exact-identity observation wait.
        dates = [entry.published_at, publication_time(release["published_at"]),
                 publication_time(asset["created_at"]), publication_time(asset["updated_at"])]
        dates.all? ? dates.max : nil
      end

      private

      def verify_current!
        formula = current.formula
        disabled = formula.disable_date ? formula.disable_date <= @now.utc.to_date : formula.disabled?
        if disabled
          reason = formula.disable_reason || formula.deprecation_reason
          raise RegistryError, "#{package.name}: trusted tap currently disables this formula: #{reason}"
        end
      end

      def commit!(value)
        raise RegistryError, "Invalid trusted tap commit" unless value.is_a?(String) && value.match?(/\A[0-9a-f]{40}\z/)

        value
      end

      def publication_time(value)
        if value.is_a?(String)
          # Time normalizes impossible calendar days; DateTime rejects them.
          DateTime.iso8601(value)
          return Time.iso8601(value).utc
        end

        @log.call(operation: "tap_publication_fallback", package: package.to_h, reason: "Publication timestamp is missing")
        nil
      rescue ArgumentError => error
        @log.call(operation: "tap_publication_fallback", package: package.to_h, reason: error.message)
        nil
      end

      def request(url)
        @log.call(operation: "read_trusted_tap", package: package.to_h, url:)
        @request.call(url)
      end
    end
  end
end
