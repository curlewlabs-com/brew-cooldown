# frozen_string_literal: true

require "utils/github"
require "digest"
require "time"
require "uri"
require "set"
require_relative "current_cask"
require_relative "../../../prototype/cask_candidate"

module BrewCooldown
  module HomebrewAdapter
    CaskHistoryEntry = Data.define(:commit, :published_at)

    # History is anchored to the current official API's source head. Responses
    # live only for the invocation; exact recipes use Homebrew's resource cache.
    class CaskHistory
      API = "https://api.github.com/repos/Homebrew/homebrew-cask"

      def initialize(current:, log:, request: GitHub::API.method(:open_rest))
        @current, @log, @request = current, log, request
      end

      # Newest first, fetched a page at a time as the caller advances. A caller
      # that stops at the installed version pays for the commits since then,
      # not for every commit the cask has ever had.
      def entries
        Enumerator.new do |results|
          seen = Set.new
          page = 1
          loop do
            query = URI.encode_www_form(path: @current.fetch("ruby_source_path"), sha: @current.fetch("tap_git_head"), per_page: 100, page:)
            rows = request("#{API}/commits?#{query}")
            raise RegistryError, "Invalid cask history page" unless rows.is_a?(Array)
            raise RegistryError, "Official cask history is empty" if page == 1 && rows.empty?

            rows.each do |row|
              commit = row.fetch("sha")
              raise RegistryError, "Invalid or repeated cask history commit" unless commit.is_a?(String) && commit.match?(/\A[0-9a-f]{40}\z/) && seen.add?(commit)

              timestamp = row.dig("commit", "committer", "date")
              results << CaskHistoryEntry.new(commit:, published_at: publication_time(timestamp, commit:))
            end
            break if rows.length < 100

            page += 1
          end
        end
      end

      def candidate(entry)
        Prototype::CaskCandidate.new(source_record(entry)).load_recipe
      end

      def source_record(entry)
        path = @current.fetch("ruby_source_path")
        content = request("#{API}/contents/#{path}?ref=#{entry.commit}")
        unless content.is_a?(Hash) && content["type"] == "file" && content["path"] == path && content["encoding"] == "base64"
          raise RegistryError, "Historical cask source is unavailable at #{entry.commit}"
        end
        bytes = content.fetch("content").delete("\n").unpack1("m0")
        blob = Digest::SHA1.hexdigest("blob #{bytes.bytesize}\0" + bytes)
        raise RegistryError, "Historical cask source blob differs" unless content["sha"] == blob

        { "name" => @current.fetch("token"), "commit" => entry.commit,
          "source_path" => path, "source_sha256" => Digest::SHA256.hexdigest(bytes) }
      end

      private

      def publication_time(timestamp, commit:)
        return Time.iso8601(timestamp).utc if timestamp.is_a?(String)

        @log.call(operation: "cask_publication_fallback", commit:, reason: "Publication timestamp is missing")
        nil
      rescue ArgumentError => error
        @log.call(operation: "cask_publication_fallback", commit:, reason: error.message)
        nil
      end

      def request(url)
        @log.call(operation: "read_cask_history", url:)
        @request.call(url)
      end
    end
  end
end
