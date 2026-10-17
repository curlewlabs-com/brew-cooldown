# frozen_string_literal: true

require "stringio"
require "tmpdir"
require_relative "../../lib/brew_cooldown/config"
require_relative "../../lib/brew_cooldown/homebrew/discovery"
require_relative "../../lib/brew_cooldown/report"

# A scheduled run spent most of its time downloading and attesting bottles of
# releases still cooling down: 47 of the 63 it prepared on 2026-10-17, none
# selectable that day. Those are now held from registry metadata, and only the
# cases where verification can change the decision still prepare.
include BrewCooldown
NOW = Time.iso8601("2026-10-17T18:00:00Z")
LOCAL_DATE_DIFFERS = Time.iso8601("2026-10-17T22:30:00-07:00")
PACKAGE = PackageId.new(kind: :formula, tap: "homebrew/core", name: "git")
CURRENT = { "name" => "git", "tap" => "homebrew/core", "version_scheme" => 0, "disabled" => false,
            "versions" => { "stable" => "2.57.0" }, "revision" => 0, "bottle" => { "stable" => { "rebuild" => 0 } } }.freeze
ADVISORIES = JSON.parse(File.read(File.expand_path("../fixtures/advisories.json", __dir__))).fetch("advisories")
Prepared = Data.define(:formula, :rebuild, :worker_record, :runtime_dependencies, :compatibility_version, :identity, :tag)
History = Data.define(:entries) do
  def tags(_name) = entries.keys
  def resolve(_name, tag, **_options) = entries.fetch(tag)
end
Metadata = Data.define(:current) do
  def fetch_all(names, log:) = names.to_h { |name| [name, current] }
end

class CountingDiscovery < HomebrewAdapter::Discovery
  attr_reader :prepared_versions

  def initialize(candidates:, **arguments)
    super(**arguments)
    @candidates, @prepared_versions = candidates, []
  end

  def prepare(metadata)
    @prepared_versions << metadata.pkg_version
    @candidates.fetch(metadata.pkg_version)
  end
end

def entry(version, published_at:)
  digest = Digest::SHA256.hexdigest(version)
  HomebrewAdapter::BottleMetadata.new(name: "git", pkg_version: version, rebuild: 0, platform: "arm64_tahoe",
    index_sha256: digest, platform_sha256: digest, bottle_sha256: digest, published_at:,
    latest_publication: published_at || Time.iso8601("2026-10-17T23:59:59Z"), runtime_dependencies: [], source: nil)
end

candidates = %w[2.56.0 2.57.0].to_h do |version|
  recipe = "class Git < Formula\n  url \"https://example.invalid/git-#{version}.tar.gz\"\n  version \"#{version}\"\nend\n"
  formula = Formulary.from_contents("git", Pathname("/git.rb"), recipe, tap: CoreTap.instance, from_metadata: true)
  [version, Prepared.new(formula:, rebuild: 0, worker_record: { "recipe_sha256" => Digest::SHA256.hexdigest(recipe) },
                         runtime_dependencies: [], compatibility_version: nil, identity: { "version" => version }, tag: "arm64_tahoe")]
end
old = Time.iso8601("2026-08-01T00:00:00Z")
young = Time.iso8601("2026-10-16T12:00:00Z")

Dir.mktmpdir("cooldown-discovery-deferral-") do |directory|
  config = Config.new({}, directory: Pathname(directory))
  discover = lambda do |installed_version, history, records: ADVISORIES, current: CURRENT, scheme: 0|
    baseline = Installed.new(package: PACKAGE, build: Build.new(version: installed_version, revision: 0, rebuild: 0, scheme:),
                             pinned: false)
    record = HomebrewAdapter::InstalledRecord.new(installed: baseline, dependencies: [], compatibility_version: nil,
      retained: nil, receipt: "receipt", identity: Digest::SHA256.hexdigest("installed #{installed_version}"))
    inventory = HomebrewAdapter::InventoryResult.new(records: { PACKAGE => record }, errors: [], fingerprint: {})
    discovery = CountingDiscovery.new(candidates:, inventory:, config:,
      advisories: HomebrewAdapter::Advisories.new(records:, validated_at: NOW),
      observations: Observations.new(directory, prefix: directory, clock: -> { NOW }), now: NOW, log: ->(**_event) {},
      registry: History.new(entries: history), current_formulae: Metadata.new(current:))
    [discovery, discovery.collect([PACKAGE])]
  end
  decision = ->(result, version) { result.decisions.find { |entry| entry.fetch(:build).fetch(:version) == version }.fetch(:decision) }

  # git 2.55.0 is outside the recorded advisory, so a young 2.57.0 cannot be
  # selected and is held without its bottle; the mature 2.56.0 is prepared.
  history = { "2.56.0" => entry("2.56.0", published_at: old), "2.57.0" => entry("2.57.0", published_at: young) }
  discovery, result = discover.call("2.55.0", history)
  raise "Cooling release was prepared: #{discovery.prepared_versions}" unless discovery.prepared_versions == ["2.56.0"]
  held = decision.call(result, "2.57.0")
  raise "Held release lost its clock: #{held}" unless held.fetch(:status) == :cooldown && held.fetch(:age_source) == :platform_manifest &&
                                                     held.fetch(:eligible_at) == young + (21 * Policy::SECONDS_PER_DAY)
  raise "Held release entered the solver" if result.domains.fetch(PACKAGE).any? { |option| option.release.build.version == "2.57.0" }
  raise "Mature release was not offered" unless decision.call(result, "2.56.0").fetch(:status) == :eligible

  # The held clock is the one a verified release gets, so holding it early
  # cannot change when it becomes eligible.
  policy = Policy.new(compare_builds: HomebrewAdapter::BuildOrder)
  installed = Installed.new(package: PACKAGE, build: Build.new(version: "2.55.0", revision: 0, rebuild: 0, scheme: 0), pinned: false)
  build = Build.new(version: "2.57.0", revision: 0, rebuild: 0, scheme: 0)
  quiet = SecurityEvidence.new(installed_affected: false, candidate_affected: false, fixed_advisories: [], validated_at: NOW)
  [NOW, LOCAL_DATE_DIFFERS].each do |now|
    verified = policy.evaluate(release: Release.new(package: PACKAGE, build:, identity: "a" * 64, verified: true, published_at: young,
                                                    publication_source: :platform_manifest), installed:, now:, security: quiet)
    unverified = policy.unverified_cooldown(build:, installed:, published_at: young, publication_source: :platform_manifest, now:,
                                            security: quiet)
    raise "Held clock differs at #{now}: #{unverified} vs #{verified}" unless unverified == verified
  end

  # An affected installation lets a young release through as a security fix,
  # which only the verified candidate can establish.
  discovery, = discover.call("2.54.0", { "2.57.0" => entry("2.57.0", published_at: young) })
  raise "Young release was held although it may fix the installation" unless discovery.prepared_versions == ["2.57.0"]

  # A release with only a calendar date takes its clock from a verified first
  # observation, so it must be prepared to start that clock.
  discovery, = discover.call("2.55.0", { "2.57.0" => entry("2.57.0", published_at: nil) })
  raise "Release needing a first observation was held" unless discovery.prepared_versions == ["2.57.0"]

  # Across a version-scheme change, ordering needs each recipe's own scheme.
  discovery, = discover.call("2.55.0", { "2.57.0" => entry("2.57.0", published_at: young) }, current: CURRENT.merge("version_scheme" => 1))
  raise "Release was held across a scheme change" unless discovery.prepared_versions == ["2.57.0"]

  # A release beyond Homebrew's current build is still excluded, not held.
  ahead = CURRENT.merge("versions" => { "stable" => "2.56.0" })
  discovery, result = discover.call("2.55.0", { "2.57.0" => entry("2.57.0", published_at: young) }, current: ahead)
  raise "Excluded release was prepared or held" unless discovery.prepared_versions.empty? && result.decisions.empty?
  raise "Exclusion was not explained" unless result.diagnostics.fetch(0).fetch(:status) == "ahead_of_current"

  # Plans and explanations show a held release like any other cooling one,
  # and say its advisories are not assessed yet.
  _discovery, result = discover.call("2.55.0", { "2.57.0" => entry("2.57.0", published_at: young) })
  report = { status: "assessed", scope: [], components: [], candidates: result.decisions, installed_security: [],
             diagnostics: result.diagnostics, errors: result.errors }
  output = StringIO.new
  Report.print_human(report, output)
  raise "Held release missing from the plan" unless output.string.include?("git 2.57.0: Candidate is still cooling down (eligible 2026-11-06T12:00:00Z)")
  output = StringIO.new
  Report.print_explanation(report.merge(explanation: { requested: "git", status: :selected, package: PACKAGE.to_h }), output)
  raise "Explanation hid the unassessed advisories" unless output.string.include?("Security coverage: not_assessed")
end
puts "PASS: cooling releases held without preparation, except where verification can change the decision"
