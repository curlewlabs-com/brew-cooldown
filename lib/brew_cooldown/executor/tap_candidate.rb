# frozen_string_literal: true

require "resource"
require "formula_installer"
require "digest"
require "uri"
require_relative "errors"

module BrewCooldown
  module Executor
    # A trusted recipe's release archive uses Homebrew's native install method,
    # not a Core bottle. Its exact source, URL and checksum authorize that path.
    class TapCandidate
      attr_reader :formula, :record, :runtime_dependencies

      def initialize(record)
        @record = record.freeze
        name, tap, repository, commit, path, digest = record.values_at("name", "tap", "repository", "commit", "source_path", "source_sha256")
        unless name.is_a?(String) && name.match?(/\A[a-z0-9][a-z0-9+@._-]*\z/) && !name.include?("..") &&
               tap.is_a?(String) && tap.match?(/\A[a-z0-9_-]+\/[a-z0-9_-]+\z/) && !%w[homebrew/core homebrew/cask].include?(tap)
          raise Refused, "invalid trusted formula identity"
        end
        owner, token = tap.split("/")
        raise Refused, "trusted tap repository differs" unless repository == "#{owner}/homebrew-#{token}"
        raise Refused, "invalid trusted source commit" unless commit.is_a?(String) && commit.match?(/\A[0-9a-f]{40}\z/)
        unless path.is_a?(String) && path.start_with?("Formula/") && path.end_with?("/#{name}.rb") &&
               path.split("/").all? { |piece| piece.match?(/\A[a-zA-Z0-9+@._-]+\z/) && !%w[. ..].include?(piece) }
          raise Refused, "invalid trusted formula path"
        end
        raise Refused, "invalid trusted source checksum" unless digest.is_a?(String) && digest.match?(/\A[0-9a-f]{64}\z/)
      end

      def load_recipe
        source = Resource.new("cooldown-tap-source-#{record.fetch('name')}")
        source.url("https://raw.githubusercontent.com/#{record.fetch('repository')}/#{record.fetch('commit')}/#{record.fetch('source_path')}")
        source.sha256(record.fetch("source_sha256"))
        source.fetch
        source.verify_download_integrity(source.cached_download)
        evaluate_recipe(source.cached_download.binread, path: source.cached_download)
      end

      def prepare
        load_recipe unless formula
        verify_shape!
        formula.resource.fetch
        verify_payload!
        @runtime_dependencies = formula.deps.reject(&:test?).map do |dependency|
          { "full_name" => dependency.name, "runtime_only" => true }
        end
        @contract = contract
        self
      end

      def verify!
        raise Refused, "#{formula.full_name}: release recipe changed after preparation" unless contract == @contract

        verify_shape!
        verify_payload!
      end

      def verify_shape!
        resource = formula.resource
        uri = URI(formula.resource.url)
        unless uri.scheme == "https" && uri.host == "github.com" && uri.query.nil? && uri.fragment.nil? &&
               uri.path.match?(%r{\A/[a-zA-Z0-9_.-]+/[a-zA-Z0-9_.-]+/releases/download/[a-zA-Z0-9_.+-]+/[a-zA-Z0-9_.+-]+\.(?:tar\.gz|tgz|zip)\z}) &&
               resource.checksum&.hexdigest&.match?(/\A[0-9a-f]{64}\z/)
          raise Refused, "#{formula.full_name}: needs a checksum-bound versioned GitHub release archive"
        end
        unless formula.stable && !formula.head? && formula.local_bottle_path.nil? && formula.bottle.nil? && formula.resources.empty? && formula.patchlist.empty? &&
               formula.options.empty? && !formula.fetch_defined? && formula.deps.none? { |dependency| dependency.build? || dependency.optional? || dependency.recommended? }
          raise Refused, "#{formula.full_name}: unsupported release installer (bottles, resources, patches, options, fetch hooks or build dependencies)"
        end
        formula.requirements.reject(&:test?).each do |requirement|
          raise Refused, "#{formula.full_name}: platform requirement is unsatisfied: #{requirement.name}" unless requirement.satisfied?
        end
      end

      def verify_payload!
        formula.resource.verify_download_integrity(formula.resource.cached_download)
        found = false
        formula.resource.stage do
          Pathname.pwd.find do |path|
            next unless path.file? && !path.symlink?

            binary = BinaryPathname.wrap(path)
            next unless binary.dylib? || binary.binary_executable? || binary.mach_o_bundle?
            raise Refused, "#{formula.full_name}: archive binary is incompatible with this architecture" unless binary.arch_compatible?(Hardware::CPU.arch)
            if binary.dynamically_linked_libraries.any? { |library| library.start_with?("#{HOMEBREW_PREFIX}/", "#{HOMEBREW_CELLAR}/") }
              raise Refused, "#{formula.full_name}: release binary needs Homebrew ABI evidence; release archive adapter cannot establish it"
            end
            found = true if binary.binary_executable? || binary.dylib?
          end
        end
        raise Refused, "#{formula.full_name}: archive contains no compatible macOS binary; source-only installation is unsupported" unless found
      end

      def build
        BrewCooldown::Build.new(version: formula.version.to_s, revision: formula.revision, rebuild: 0, scheme: formula.version_scheme)
      end

      def identity
        record.merge("version" => formula.pkg_version.to_s, "url" => formula.resource.url,
                     "sha256" => formula.resource.checksum.hexdigest, "platform" => Utils::Bottles.tag.to_s)
      end

      def worker_record
        { "name" => formula.full_name, "tap" => record.fetch("tap"), "version" => formula.pkg_version.to_s,
          "path" => formula.path.to_s, "recipe" => @contents, "recipe_sha256" => record.fetch("source_sha256"),
          "commit" => record.fetch("commit"), "release_archive" => true }
      end

      def install? = true
      def release_archive? = true
      def compatibility_version = nil
      def rebuild = 0

      private

      def evaluate_recipe(contents, path:)
        raise Refused, "trusted source changed before evaluation" unless Digest::SHA256.hexdigest(contents) == record.fetch("source_sha256")

        @contents = contents
        tap = Tap.fetch(record.fetch("tap"))
        # The immutable cache path prevents a later historical evaluation from
        # reusing a class cached for today's live tap path.
        @formula = Formulary.from_contents(record.fetch("name"), path, @contents, tap:)
        raise Refused, "trusted formula identity differs" unless formula.full_name == "#{record.fetch('tap')}/#{record.fetch('name')}"

        commit = record.fetch("commit")
        formula.define_singleton_method(:tap_git_head) { commit }
        self
      end

      def contract
        JSON.generate(identity:, dependencies: formula.deps.map { |dependency| [dependency.name, dependency.tags] },
                      requirements: formula.requirements.map(&:inspect))
      end
    end
  end
end
