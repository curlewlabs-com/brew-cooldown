# frozen_string_literal: true

require "digest"
require "json"
require_relative "../policy"

module BrewCooldown
  module HomebrewAdapter
    module CandidateEvidence
      def self.release(package, candidate, metadata)
        formula = candidate.formula
        build = Build.new(version: formula.version.to_s, revision: formula.revision,
                          rebuild: candidate.rebuild, scheme: formula.version_scheme)
        # An index can gain another platform without changing this artifact.
        # Only the selected platform, recipe and bottle belong in its clock key.
        identity = Digest::SHA256.hexdigest(JSON.generate(package: package.to_h, build: build.to_h,
                                                        platform: metadata.platform, manifest: metadata.platform_sha256,
                                                        bottle: metadata.bottle_sha256,
                                                        recipe: candidate.worker_record.fetch("recipe_sha256")))
        Release.new(package:, build:, identity:, verified: true, published_at: metadata.published_at,
                    publication_source: metadata.published_at && :platform_manifest)
      end
    end
  end
end
