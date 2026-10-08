# frozen_string_literal: true

require "digest"
require "json"
require_relative "../policy"

module BrewCooldown
  module HomebrewAdapter
    module TapEvidence
      def self.release(package, candidate, published_at:)
        identity = Digest::SHA256.hexdigest(JSON.generate(package: package.to_h, build: candidate.build.to_h,
          platform: Utils::Bottles.tag.to_s, recipe: candidate.record.fetch("source_sha256"),
          url: candidate.formula.resource.url, archive: candidate.formula.resource.checksum.hexdigest))
        Release.new(package:, build: candidate.build, identity:, verified: true, published_at:,
                    publication_source: published_at && :trusted_recipe_and_release_asset)
      end
    end
  end
end
