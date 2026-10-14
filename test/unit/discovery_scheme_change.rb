# frozen_string_literal: true

require "tmpdir"
require_relative "../../lib/brew_cooldown/config"
require_relative "../../lib/brew_cooldown/homebrew/discovery"

include BrewCooldown
NOW = Time.iso8601("2026-09-19T06:30:00Z")
PACKAGE = PackageId.new(kind: :formula, tap: "homebrew/core", name: "example")
# Homebrew moved the formula back to an older release line and raised its
# version scheme so the older version still sorts as newer, as it did when
# openssl@3 moved from 3.6 to the 3.5 long-term line.
CURRENT = { "name" => "example", "tap" => "homebrew/core", "version_scheme" => 1, "disabled" => false,
            "versions" => { "stable" => "1.1.9" }, "revision" => 0, "bottle" => { "stable" => { "rebuild" => 0 } } }.freeze
Prepared = Data.define(:formula, :rebuild, :worker_record, :runtime_dependencies, :compatibility_version, :identity, :tag)
History = Data.define(:entries) do
  def tags(_name) = entries.keys
  def resolve(_name, tag, **_options) = entries.fetch(tag)
end
Metadata = Data.define(:current) do
  def fetch_all(names, log:) = names.to_h { |name| [name, current] }
end

# Artifact preparation is the external boundary here, and the step this bound
# exists to avoid. Native version handling, discovery and evaluation are real.
class PreparedDiscovery < HomebrewAdapter::Discovery
  attr_reader :attempted

  def initialize(candidates:, **arguments)
    super(**arguments)
    @candidates, @attempted = candidates, []
  end

  def prepare(metadata)
    @attempted << metadata.pkg_version
    candidate = @candidates.fetch(metadata.pkg_version)
    raise candidate if candidate.is_a?(Exception)

    candidate
  end
end

def bottle(version, published_at:, latest_publication: published_at)
  digest = Digest::SHA256.hexdigest(version)
  HomebrewAdapter::BottleMetadata.new(name: "example", pkg_version: version, rebuild: 0, platform: "arm64_tahoe",
    index_sha256: digest, platform_sha256: digest, bottle_sha256: digest, published_at:, latest_publication:,
    runtime_dependencies: [], source: nil)
end

def prepared(version, scheme)
  recipe = "class Example < Formula\n  url \"https://example.invalid/example-#{version}.tar.gz\"\n  " \
           "version \"#{version}\"\n  version_scheme #{scheme}\nend\n"
  formula = Formulary.from_contents("example", Pathname("/example.rb"), recipe, tap: CoreTap.instance, from_metadata: true)
  Prepared.new(formula:, rebuild: 0, worker_record: { "recipe_sha256" => Digest::SHA256.hexdigest(recipe) },
    runtime_dependencies: [], compatibility_version: nil, identity: { "version" => version }, tag: "arm64_tahoe")
end

# Bottles this old predate Homebrew's attestations, so preparing one fails.
unattested = Executor::Refused.new("attestation not found")
floor = Time.iso8601("2026-09-01T06:00:00Z")
entries = {
  "1.2.1" => bottle("1.2.1", published_at: floor),
  "1.2.0" => bottle("1.2.0", published_at: Time.iso8601("2026-08-01T00:00:00Z")),
  "1.1.9" => bottle("1.1.9", published_at: Time.iso8601("2026-09-10T00:00:00Z")),
  "1.1.8" => bottle("1.1.8", published_at: Time.iso8601("2025-06-01T00:00:00Z")),
  "1.0.0" => bottle("1.0.0", published_at: nil, latest_publication: Time.iso8601("2023-12-07T12:00:00Z")),
}
candidates = { "1.2.1" => prepared("1.2.1", 0), "1.2.0" => prepared("1.2.0", 0), "1.1.9" => prepared("1.1.9", 1),
               "1.1.8" => unattested, "1.0.0" => unattested, "1.1.7" => unattested }

baseline = Installed.new(package: PACKAGE, build: Build.new(version: "1.2.0", revision: 0, rebuild: nil, scheme: 0), pinned: false)
record = HomebrewAdapter::InstalledRecord.new(installed: baseline, dependencies: [], compatibility_version: nil,
  retained: nil, receipt: "receipt", identity: Digest::SHA256.hexdigest("installed"))
inventory = HomebrewAdapter::InventoryResult.new(records: { PACKAGE => record }, errors: [], fingerprint: {})

Dir.mktmpdir("cooldown-scheme-change-") do |directory|
  config = Config.new({}, directory: Pathname(directory))
  discover = lambda do |history|
    discovery = PreparedDiscovery.new(candidates:, inventory:, config:,
      advisories: HomebrewAdapter::Advisories.new(records: {}, validated_at: NOW),
      observations: Observations.new(directory, prefix: directory, clock: -> { NOW }), now: NOW, log: ->(**_event) {},
      registry: History.new(entries: history), current_formulae: Metadata.new(current: CURRENT))
    [discovery.collect([PACKAGE]), discovery.attempted]
  end

  # The verified 1.2.1 recipe still has the installed scheme, so everything
  # published before it is ordered by version alone. The rescheme release
  # published after it is still prepared and offered.
  result, attempted = discover.call(entries)
  raise "Pre-scheme history was prepared: #{attempted}" unless attempted == %w[1.2.1 1.1.9]
  raise "Bounded history failed assessment: #{result.errors}" unless result.errors.empty?
  offered = result.domains.fetch(PACKAGE).reject(&:retained).map { |option| [option.release.build.version, option.release.build.scheme] }
  raise "Scheme-change candidates were lost: #{offered}" unless offered == [["1.2.1", 0], ["1.1.9", 1]]

  # Without a verified build of the installed scheme there is no publication
  # evidence to bound the walk. Old bottles are still inspected, and their
  # failures stay visible rather than being treated as superseded.
  result, attempted = discover.call(entries.slice("1.1.9", "1.1.8", "1.0.0"))
  raise "Unbounded history was skipped: #{attempted}" unless attempted == %w[1.1.9 1.1.8 1.0.0]
  raise "Unbounded failures were hidden" unless result.errors.map { |error| error.fetch(:tag) } == %w[1.1.8 1.0.0]

  # A calendar-only date is not an instant, so it cannot set the floor.
  undated = entries.merge("1.2.1" => bottle("1.2.1", published_at: nil, latest_publication: floor))
  result, attempted = discover.call(undated.slice("1.2.1", "1.1.8"))
  raise "A calendar date bounded the walk" unless attempted == %w[1.2.1 1.1.8] && result.errors.one?

  # Built late on 2026-08-31 in a zone behind UTC, this bottle can postdate
  # the floor even though that UTC date ended six hours before it.
  late = entries.merge("1.1.7" => bottle("1.1.7", published_at: nil, latest_publication: Time.iso8601("2026-09-01T12:00:00Z")))
  result, attempted = discover.call(late)
  raise "An ambiguous calendar date was bounded: #{attempted}" unless attempted == %w[1.2.1 1.1.9 1.1.7]
  raise "The ambiguous bottle's failure was hidden" unless result.errors.map { |error| error.fetch(:tag) } == ["1.1.7"]
end
puts "PASS: a version-scheme change bounds its walk at verified publication evidence and keeps unbounded failures visible"
