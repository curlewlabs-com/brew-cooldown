# frozen_string_literal: true

require "stringio"
require_relative "../../lib/brew_cooldown/planning"
require_relative "../../lib/brew_cooldown/report"

# On 2026-10-14 Homebrew's feed published BREW-git-CVE-2026-86219 against the
# Authen::SASL resource vendored into git, with no fixed release. Every run then
# failed on it, and that failure hid an unrelated one behind it for days.
package = BrewCooldown::PackageId.new(kind: :formula, tap: "homebrew/core", name: "git")
affected = BrewCooldown::HomebrewAdapter::SecurityAssessment.new(
  evidence: BrewCooldown::SecurityEvidence.new(installed_affected: true, candidate_affected: true, fixed_advisories: [], validated_at: nil),
  coverage: :assessed_records, diagnostics: [], source: "test",
  advisories: [BrewCooldown::HomebrewAdapter::AdvisoryResult.new(id: "BREW-git-CVE-2026-86219", installed_state: :affected,
                                                   candidate_state: :affected, fixed: false, reason: nil)],
)
option = lambda do |status, retained: false|
  build = BrewCooldown::Build.new(version: "2.56.0", revision: 0, rebuild: 0, scheme: 0)
  release = BrewCooldown::Release.new(package:, build:, identity: status.to_s, verified: true, published_at: nil,
                                      publication_source: nil)
  decision = BrewCooldown::Decision.new(status:, reason: "test", eligible_at: nil, delay_kind: nil, age_source: nil,
                                        fixed_advisories: [])
  BrewCooldown::Option.new(release:, decision:, dependencies: [], compatibility_version: nil, retained:)
end
finding = ->(candidates, selected: nil) { BrewCooldown::Planning.security_finding(package:, assessment: affected, selected:, candidates:) }

# Nothing published fixes it, whether no newer release exists or every one is
# still affected: the run reports the advisory and keeps its verdict.
[[], [option.call(:affected), option.call(:affected)]].each do |candidates|
  result = finding.call(candidates, selected: option.call(:retained, retained: true))
  raise "Unfixable advisory failed the run: #{result}" unless result&.key?(:warning) && !result.key?(:error)
  raise "Warning lost the advisory" unless result.fetch(:advisories) == ["BREW-git-CVE-2026-86219"] &&
                                           result.fetch(:warning).include?("BREW-git-CVE-2026-86219")
end

# A release the plan did not take may fix it, and one stopped before its
# advisory check may too. A pin is the operator's to lift. Each stays an error.
%i[cooldown eligible security_fix pinned unverified needs_observation].each do |status|
  result = finding.call([option.call(:affected), option.call(status)])
  raise "#{status} candidate downgraded to a warning" unless result&.key?(:error) && !result.key?(:warning)
end
raise "Selected upgrade reported" if finding.call([option.call(:security_fix)], selected: option.call(:security_fix))
unaffected = affected.with(evidence: affected.evidence.with(installed_affected: false))
raise "Unaffected installation reported" if BrewCooldown::Planning.security_finding(package:, assessment: unaffected, selected: nil, candidates: [])

# The warning names the package at the end of the report, where a log tail
# shows it, and leaves the assessment's status alone.
output = StringIO.new
BrewCooldown::Report.print_human({ status: "assessed", scope: [], components: [], candidates: [], installed_security: [],
                                   errors: [], warnings: [finding.call([])] }, output)
lines = output.string.lines.map(&:chomp)
raise "Status changed: #{lines.first}" unless lines.first == "Homebrew cooldown plan: assessed"
raise "Warning missing: #{output.string}" unless lines.last.start_with?("Warning: git: Installed version is affected by BREW-git-CVE-2026-86219")
puts "PASS: unfixable advisories warn without failing; fixes not taken stay errors"
