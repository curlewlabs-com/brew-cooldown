# frozen_string_literal: true

require_relative "installed_inventory"

module BrewCooldown
  module HomebrewAdapter
    module CaskEvidence
      def self.release(package, candidate, published_at:)
        build = Build.new(version: candidate.cask.version.to_s, revision: 0, rebuild: 0, scheme: 0)
        identity = Digest::SHA256.hexdigest(JSON.generate(package: package.to_h, build: build.to_h,
          platform: Utils::Bottles.tag.to_s, recipe: candidate.record.fetch("source_sha256"), payload: candidate.cask.sha256.to_s))
        Release.new(package:, build:, identity:, verified: true, published_at:,
                    publication_source: published_at && :homebrew_source_commit)
      end

      def self.requirements(cask)
        rows = { "formula" => cask.depends_on.formula.map { |name| { "full_name" => name } },
                 "cask" => cask.depends_on.cask.map { |name| { "full_name" => name } } }
        InstalledInventory.cask_requirements(rows)
      end
    end
  end
end
