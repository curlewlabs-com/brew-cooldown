# frozen_string_literal: true

require "stringio"
require "tmpdir"
require_relative "../../lib/brew_cooldown/config"
require_relative "../../lib/brew_cooldown/homebrew/discovery"
require_relative "../../lib/brew_cooldown/homebrew/revalidation"
require_relative "../../lib/brew_cooldown/report"

include BrewCooldown
NOW = Time.iso8601("2026-09-19T06:30:00Z")
PACKAGE = PackageId.new(kind: :formula, tap: "homebrew/core", name: "example")
CURRENT = { "name" => "example", "tap" => "homebrew/core", "version_scheme" => 0, "disabled" => false,
            "versions" => { "stable" => "1.0.1" }, "revision" => 0, "bottle" => { "stable" => { "rebuild" => 0 } } }.freeze
Prepared = Data.define(:formula, :rebuild, :worker_record, :runtime_dependencies, :compatibility_version, :identity, :tag)
History = Data.define(:entries) do
  def tags(_name) = entries.keys
  def resolve(_name, tag, **_options) = entries.fetch(tag)
end
Metadata = Data.define(:current) do
  def fetch_all(names, log:) = names.to_h { |name| [name, current] }
end

# Artifact preparation is the external boundary here. Native formula/version
# handling, discovery, eligibility, solver selection and reporting remain real;
# these fixtures make no claim about bottle authenticity or installation.
class PreparedDiscovery < HomebrewAdapter::Discovery
  def initialize(candidates:, **arguments)
    super(**arguments)
    @candidates = candidates
  end

  def prepare(metadata)
    candidate = @candidates.fetch(metadata.pkg_version)
    raise candidate if candidate.is_a?(Exception)

    candidate
  end
end

entries, candidates = {}, {}
%w[1.0.1 1.0.2].each do |version|
  recipe = "class Example < Formula\n  url \"https://example.invalid/example-#{version}.tar.gz\"\n  version \"#{version}\"\nend\n"
  formula = Formulary.from_contents("example", Pathname("/example.rb"), recipe, tap: CoreTap.instance, from_metadata: true)
  digest = Digest::SHA256.hexdigest(recipe)
  entries[version] = HomebrewAdapter::BottleMetadata.new(name: "example", pkg_version: version, rebuild: 0,
    platform: "arm64_tahoe", index_sha256: digest, platform_sha256: digest, bottle_sha256: digest,
    published_at: Time.iso8601("2026-08-01T00:00:00Z"), runtime_dependencies: [], source: nil)
  candidates[version] = Prepared.new(formula:, rebuild: 0, worker_record: { "recipe_sha256" => digest },
    runtime_dependencies: [], compatibility_version: nil, identity: { "version" => version }, tag: "arm64_tahoe")
end

baseline = Installed.new(package: PACKAGE, build: Build.new(version: "1.0.0", revision: 0, rebuild: nil, scheme: 0), pinned: false)
record = HomebrewAdapter::InstalledRecord.new(installed: baseline, dependencies: [], compatibility_version: nil,
  retained: nil, receipt: "receipt", identity: Digest::SHA256.hexdigest("installed"))
inventory = HomebrewAdapter::InventoryResult.new(records: { PACKAGE => record }, errors: [], fingerprint: {})

Dir.mktmpdir("cooldown-discovery-bounds-") do |directory|
  config = Config.new({}, directory: Pathname(directory))
  events = []
  log = ->(**event) { events << event }
  discover = lambda do |history, prepared, current = CURRENT|
    PreparedDiscovery.new(candidates: prepared, inventory:, config:,
      advisories: HomebrewAdapter::Advisories.new(records: {}, validated_at: NOW),
      observations: Observations.new(directory, prefix: directory, clock: -> { NOW }), now: NOW, log:,
      registry: History.new(entries: history), current_formulae: Metadata.new(current:)).collect([PACKAGE])
  end
  planner = Planner.new(compare_builds: HomebrewAdapter::BuildOrder, compatible: HomebrewAdapter::Compatibility)

  # A registry release beyond the API bound is unusable whether it is newly
  # published or left behind by a rollback. It must not hide an older upgrade.
  result = discover.call(entries, candidates)
  raise "An excluded build failed discovery: #{result.errors}" unless result.errors.empty?
  selected = planner.plan(domains: result.domains, roots: [PACKAGE]).first.selected.fetch(PACKAGE)
  raise "Older eligible candidate was lost" unless selected.release.build.version == "1.0.1" && !selected.retained
  raise "Excluded build entered the solver" if result.domains.fetch(PACKAGE).any? { |option| option.release.build.version == "1.0.2" }
  note = result.diagnostics.fetch(0)
  raise "Excluded build was not explained" unless note.fetch(:status) == "ahead_of_current" && note.fetch(:tag) == "1.0.2"
  report = { status: "assessed", scope: [], components: [], candidates: result.decisions, installed_security: [],
             diagnostics: result.diagnostics, errors: result.errors }
  output = StringIO.new
  Report.print_human(report, output)
  raise "Terminal exclusion was hidden or treated as an error" unless output.string.include?("Note:") &&
    output.string.include?("1.0.2") && output.string.include?("1.0.1") && !output.string.include?("Error:")
  serialized = JSON.parse(JSON.generate(Report.json_value(report)))
  raise "JSON exclusion lost its package" unless serialized.fetch("diagnostics").first.fetch("package").fetch("name") == "example"

  # A complete history containing only excluded releases is a completed
  # assessment with no upgrade, not evidence of a failed registry read.
  result = discover.call(entries.slice("1.0.2"), candidates)
  raise "Only excluded candidates failed discovery" unless result.errors.empty?
  raise "An excluded release replaced the installation" unless planner.plan(domains: result.domains, roots: [PACKAGE]).first.selected.fetch(PACKAGE).retained

  # Exclusion must not waive the remaining candidate's own cooldown.
  cooling = entries.merge("1.0.1" => entries.fetch("1.0.1").with(published_at: Time.iso8601("2026-09-18T23:15:00-07:00")))
  result = discover.call(cooling, candidates)
  raise "Cooldown or exclusion failed assessment" unless result.errors.empty?
  raise "Remaining candidate was not cooling down" unless result.decisions.first.fetch(:decision).fetch(:status) == :cooldown
  raise "A cooling release was installed early" unless planner.plan(domains: result.domains, roots: [PACKAGE]).first.selected.fetch(PACKAGE).retained

  # Only a conclusive comparison is an exclusion. Evidence failures must stay
  # visible even when another candidate has already been excluded normally.
  invalid = candidates.merge("1.0.1" => Executor::Refused.new("bottle attestation failed"))
  result = discover.call(entries, invalid)
  raise "Failed verification became an exclusion" unless result.errors.one? && result.errors.first.fetch(:error) == "bottle attestation failed"
  result = discover.call(entries, candidates, CURRENT.reject { |key, _| key == "bottle" })
  raise "Missing rebuild evidence became an exclusion" unless result.errors.one? && result.errors.first.fetch(:tag) == "1.0.1"

  # Discovery's exception handling must not leak into the pre-install path:
  # a formerly selected build above the refreshed bound must still refuse.
  original_fetch = HomebrewAdapter::CurrentFormula.method(:fetch)
  begin
    HomebrewAdapter::CurrentFormula.define_singleton_method(:fetch) { |_name, log:| CURRENT }
    revalidation = HomebrewAdapter::Revalidation.new(config:, inventory:, prepared: {}, state_directory: directory, log:, clock: -> { NOW })
    begin
      revalidation.send(:formula_release, PACKAGE, candidates.fetch("1.0.2"), History.new(entries:), verify_payload: false)
    rescue HomebrewAdapter::CurrentFormula::AheadOfCurrent
      refused = true
    end
    raise "Pre-install revalidation accepted an excluded build" unless refused
  ensure
    HomebrewAdapter::CurrentFormula.define_singleton_method(:fetch, original_fetch)
  end
end
puts "PASS: discovery exclusions preserve older upgrades, cooldowns, evidence failures and pre-install refusal"
