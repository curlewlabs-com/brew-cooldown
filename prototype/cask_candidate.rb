# frozen_string_literal: true

require "resource"
require "cask/cask_loader"
require "cask/download"
require "digest"
require_relative "errors"

module BrewCooldown
  module Prototype
    # An official historical recipe and its native cask download. Source and
    # payload caches remain owned by Homebrew, including native checksum checks.
    class CaskCandidate
      attr_reader :cask, :download, :record

      def initialize(record)
        @record = record
        name, commit, path = record.values_at("name", "commit", "source_path")
        raise Refused, "invalid cask name" unless name.is_a?(String) && name.match?(/\A[a-z0-9][a-z0-9+@._-]*\z/) && !name.include?("..")
        raise Refused, "invalid cask commit" unless commit.is_a?(String) && commit.match?(/\A[0-9a-f]{40}\z/)
        raise Refused, "invalid official cask path" unless path == "Casks/#{name[0]}/#{name}.rb"
        raise Refused, "invalid cask source checksum" unless record.fetch("source_sha256").match?(/\A[0-9a-f]{64}\z/)
      end

      def load_recipe
        source = Resource.new("cooldown-cask-source-#{record.fetch('name')}")
        source.url("https://raw.githubusercontent.com/Homebrew/homebrew-cask/#{record.fetch('commit')}/#{record.fetch('source_path')}")
        source.sha256(record.fetch("source_sha256"))
        source.fetch
        source.verify_download_integrity(source.cached_download)
        @cask = SourceLoader.new(source.cached_download, name: record.fetch("name"), commit: record.fetch("commit")).load(config: nil)
        unless cask.token == record.fetch("name") && cask.tap&.name == "homebrew/cask" &&
               (!record.key?("version") || cask.version.to_s == record.fetch("version"))
          raise Refused, "historical cask identity differs"
        end
        @record = record.merge("version" => cask.version.to_s).freeze
        self
      end

      def prepare
        load_recipe unless @cask
        raise Refused, "cask needs a concrete version and checksum" if cask.version.latest? || !cask.sha256.is_a?(Checksum)
        raise Refused, "self-updating cask needs a separate execution contract" if cask.auto_updates
        allowed = [Cask::Artifact::Binary, Cask::Artifact::GeneratedCompletion, Cask::Artifact::Zap]
        unsupported = cask.artifacts.reject { |artifact| allowed.include?(artifact.class) }
        raise Refused, "unvalidated cask artifacts: #{unsupported.map { |artifact| artifact.class.name }.join(', ')}" unless unsupported.empty?

        @download = Cask::Download.new(cask, require_sha: true)
        cask.download = download.fetch
        @contract = installation_contract
        self
      end

      def verify!
        raise Refused, "#{cask.token}: evaluated cask changed after preparation" unless installation_contract == @contract

        download.verify_download_integrity(cask.download)
        raise Refused, "#{cask.token}: cask is pinned" if cask.pinned?
      end

      def install? = true

      private

      def installation_contract
        JSON.generate(token: cask.full_name, version: cask.version.to_s, url: cask.url.to_s,
                      sha256: cask.sha256.to_s, formula_dependencies: cask.depends_on.formula,
                      cask_dependencies: cask.depends_on.cask, artifacts: cask.artifacts_list)
      end

      class SourceLoader < Cask::CaskLoader::FromPathLoader
        def initialize(path, name:, commit:)
          # Native cached-file evaluation preserves historical DSL support and
          # accurate source locations. The cache filename is not a cask token.
          super(path)
          @name, @commit = name, commit
        end

        def token = @name
        def tap = CoreCaskTap.instance

        private

        def cask(token, **options, &block)
          loaded = super(token, **options, &block)
          # The official tap may be API-only on this machine. Bind native
          # receipt provenance to the verified source commit, not a local tap.
          commit = @commit
          loaded.define_singleton_method(:tap_git_head) { commit }
          loaded
        end
      end
    end
  end
end
