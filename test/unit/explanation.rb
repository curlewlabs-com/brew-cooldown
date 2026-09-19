# frozen_string_literal: true

require "stringio"
require "json"
require "time"
require_relative "../../lib/brew_cooldown/policy"
require_relative "../../lib/brew_cooldown/explanation"
require_relative "../../lib/brew_cooldown/report"

package = BrewCooldown::PackageId.new(kind: :formula, tap: "homebrew/core", name: "tool")
build = BrewCooldown::Build.new(version: "1.2.0", revision: 0, rebuild: nil, scheme: 0)
installed = BrewCooldown::Installed.new(package:, build:, pinned: false)
boundary = Time.iso8601("2026-09-18T23:45:00-07:00")
candidate = { package: package.to_h, identity: "a" * 64, build: build.with(version: "1.2.1", rebuild: 0).to_h,
  decision: { status: :eligible, reason: "Candidate completed its cooldown", eligible_at: boundary,
              delay_kind: :patch, age_source: :registry, fixed_advisories: [] },
  security: { coverage: :no_records } }
blocker = "outside consumer requires library compatible with 1.0.0"
result = { schema: 1, command: "plan", status: "assessed",
  scope: [{ requested: "tool-alias", package: package.to_h, status: :selected }],
  candidates: [candidate],
  components: [{ roots: [package.to_h], status: :unchanged, reason: blocker,
    selected: [{ package: package.to_h, operation: "retain" }], rejected_options: { candidate.fetch(:identity) => blocker } }],
  installed_security: [{ package: package.to_h, coverage: :no_records }], errors: [], diagnostics: [] }

# Alias and canonical queries must resolve the same native package without
# adding it to scope or discarding the consumer that prevents its upgrade.
%w[tool tool-alias homebrew/core/tool formula:homebrew/core/tool].each do |name|
  report = BrewCooldown::Explanation.call(result, requested: name, installed: [installed])
  raise "Package match lost its native baseline" unless report.fetch(:explanation).fetch(:installed) == installed.to_h
  raise "Explanation narrowed the actual assessment" unless report.fetch(:scope) == result.fetch(:scope) &&
    report.fetch(:components) == result.fetch(:components)
  output = StringIO.new
  BrewCooldown::Report.print_explanation(report, output)
  ["Installed: 1.2.0", "rebuild unknown", "Candidate 1.2.1", blocker, "2026-09-19T06:45:00Z", "no_records"].each do |evidence|
    raise "Explanation hid #{evidence}" unless output.string.include?(evidence)
  end
  json = JSON.parse(JSON.generate(BrewCooldown::Report.json_value(report)))
  raise "Native baseline serialized as text" unless json.fetch("explanation").fetch("installed").fetch("build").fetch("version") == "1.2.0"
end

# A security bypass must name the proven fixes rather than looking like an
# ordinary mature release or an assurance that no vulnerabilities exist.
security_candidate = candidate.merge(decision: candidate.fetch(:decision).merge(status: :security_fix,
  reason: "Fresh advisory evidence proves an installed vulnerability is fixed", fixed_advisories: ["GHSA-test-fix"]),
  security: { coverage: :matched_advisories })
report = BrewCooldown::Explanation.call(result.merge(candidates: [security_candidate]), requested: "tool", installed: [installed])
output = StringIO.new
BrewCooldown::Report.print_explanation(report, output)
raise "Security bypass evidence hidden" unless output.string.include?("security_fix") && output.string.include?("GHSA-test-fix")

# Same-token formulae and casks need kind-qualified identities; a tap-qualified
# name alone cannot resolve a same-tap kind collision either.
cask = package.with(kind: :cask)
collision = result.merge(scope: result.fetch(:scope) + [{ requested: "tool", package: cask.to_h, status: :selected }])
%w[tool homebrew/core/tool].each do |name|
  report = BrewCooldown::Explanation.call(collision, requested: name, installed: [installed])
  raise "Ambiguous identity silently selected" unless report[:status] == "incomplete" && report[:explanation][:status] == :ambiguous &&
    report[:explanation][:reason].include?("cask:homebrew/core/tool")
end
report = BrewCooldown::Explanation.call(collision, requested: "formula:homebrew/core/tool", installed: [installed])
raise "Canonical identity remained ambiguous" unless report[:explanation][:package] == package.to_h

# An out-of-scope query must not widen authorization or hide another root's
# failed assessment. A successful focused view is not a successful full plan.
failure = result.merge(status: "incomplete", errors: [{ error: "Other root has unreadable receipts" }])
report = BrewCooldown::Explanation.call(failure, requested: "unlisted", installed: [installed])
raise "Outside query widened scope or hid failure" unless report[:explanation][:status] == :outside_scope &&
  report[:scope] == result[:scope] && report[:status] == "incomplete"
output = StringIO.new
BrewCooldown::Report.print_explanation(report, output)
raise "Scope failure disappeared from terminal output" unless output.string.include?("Other root has unreadable receipts")

# A missing root remains explainable without inventing an installed version;
# a pin must remain visible even when discovery has no candidate records.
%i[missing pinned].each do |status|
  report = BrewCooldown::Explanation.call(result.merge(scope: [{ requested: "tool", package: package.to_h, status: }], candidates: []),
    requested: "tool", installed: status == :missing ? [] : [installed.with(pinned: true)])
  output = StringIO.new
  BrewCooldown::Report.print_explanation(report, output)
  raise "Scope hold hidden" unless output.string.include?("tool: #{status}")
  raise "Missing baseline was fabricated" if status == :missing && output.string.include?("Installed:")
end
puts "PASS: package identity, native baseline, dependency blockers and scope failures in explanations"
