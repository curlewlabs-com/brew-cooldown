# frozen_string_literal: true

require "json"
require "time"
require_relative "../../lib/brew_cooldown/homebrew/advisories"

started = Time.now.utc
log = ->(**event) { warn JSON.generate(event) }
adapter = BrewCooldown::HomebrewAdapter::Advisories.refresh(now: started, log:)
package = BrewCooldown::PackageId.new(kind: :formula, tap: "homebrew/core", name: "git")
before = BrewCooldown::Build.new(version: "2.54.0", revision: 0, rebuild: 0, scheme: 0)
installed = BrewCooldown::Installed.new(package:, build: before, pinned: false)
release = BrewCooldown::Release.new(package:, build: before.with(version: "2.55.0"), identity: nil,
                                    verified: false, published_at: nil, publication_source: nil)
assessment = adapter.assess(release:, installed:)
raise "Live refresh failed: #{assessment.diagnostics.inspect}" unless assessment.evidence.validated_at == started
raise "Live advisory assessment failed: #{assessment.inspect}" unless assessment.coverage == :assessed_records
puts JSON.pretty_generate(source: assessment.source, coverage: assessment.coverage,
                          evidence: assessment.evidence.to_h, advisories: assessment.advisories.map(&:to_h))
puts "PASS: live native advisory refresh and exact-version assessment (no package changes)"
