# frozen_string_literal: true

require "tmpdir"
require "time"
require_relative "../../lib/brew_cooldown/config"
require_relative "../../lib/brew_cooldown/homebrew/discovery"

NOW = Time.iso8601("2026-09-19T06:30:00Z")

def package(name)
  BrewCooldown::PackageId.new(kind: :formula, tap: "homebrew/core", name:)
end

def installed(name, version, revision: 0, scheme: 0, pinned: false)
  build = BrewCooldown::Build.new(version:, revision:, rebuild: nil, scheme:)
  baseline = BrewCooldown::Installed.new(package: package(name), build:, pinned:)
  BrewCooldown::HomebrewAdapter::InstalledRecord.new(installed: baseline, dependencies: [], compatibility_version: nil,
                                                    retained: nil, receipt: "receipt", identity: Digest::SHA256.hexdigest(name))
end

def published(name, version, revision: 0, scheme: 0, rebuild: 0)
  { "name" => name, "tap" => "homebrew/core", "version_scheme" => scheme, "disabled" => false,
    "versions" => { "stable" => version }, "revision" => revision, "bottle" => { "stable" => { "rebuild" => rebuild } } }
end

# The registry answers with no tags, so a walk that does begin ends without
# preparing a candidate. What matters here is which packages reach it at all.
class RecordedRegistry
  attr_reader :walked

  def initialize
    @walked = []
  end

  def tags(name)
    @walked << name
    []
  end
end

class RecordedMetadata
  attr_reader :batches, :single

  def initialize(current, batch_omits:)
    @current, @batch_omits, @batches, @single = current, batch_omits, [], []
  end

  def fetch_all(names, log:)
    @batches << names
    (names - @batch_omits).to_h { |name| [name, @current.fetch(name)] }
  end

  def fetch(name, log:)
    @single << name
    @current.fetch(name)
  end
end

def discover(records, current, roots: records.keys, batch_omits: [])
  Dir.mktmpdir("cooldown-discovery-") do |directory|
    inventory = BrewCooldown::HomebrewAdapter::InventoryResult.new(records:, errors: [], fingerprint: {})
    registry = RecordedRegistry.new
    metadata = RecordedMetadata.new(current, batch_omits:)
    discovery = BrewCooldown::HomebrewAdapter::Discovery.new(
      inventory:, config: BrewCooldown::Config.new({}, directory: Pathname(directory)),
      advisories: BrewCooldown::HomebrewAdapter::Advisories.new(records: {}, validated_at: nil),
      observations: BrewCooldown::Observations.new(directory, prefix: directory, clock: -> { NOW }), now: NOW, log: ->(**_event) {},
      registry:, current_formulae: metadata
    )
    [discovery.collect(roots), registry, metadata]
  end
end

records = {
  package("current") => installed("current", "1.2.3"),
  package("repackaged") => installed("repackaged", "2.0.0", revision: 1),
  package("behind") => installed("behind", "1.2.2"),
  package("revised") => installed("revised", "1.2.3"),
  package("rescheme") => installed("rescheme", "1.2.3"),
  package("ahead") => installed("ahead", "1.2.4"),
  package("held") => installed("held", "1.0.0", pinned: true),
}
current = {
  "current" => published("current", "1.2.3"),
  "repackaged" => published("repackaged", "2.0.0", revision: 1, rebuild: 2),
  "behind" => published("behind", "1.2.3"),
  "revised" => published("revised", "1.2.3", revision: 1),
  "rescheme" => published("rescheme", "1.2.3", scheme: 1),
  "ahead" => published("ahead", "1.2.3"),
}
result, registry, metadata = discover(records, current)

# An up-to-date package costs its share of one batched read and nothing else.
# Only a difference from Homebrew's current build earns a registry walk.
raise "Registry walked for an installed current build: #{registry.walked}" unless
  registry.walked.sort == %w[ahead behind rescheme revised]
raise "Scope was not read in one batch: #{metadata.batches}" unless metadata.batches.length == 1 && metadata.single.empty?
raise "A pinned package was read" if metadata.batches.first.include?("held")
raise "Discovery reported an error: #{result.errors}" unless result.errors.empty?
raise "An up-to-date package gained an option" unless result.domains.fetch(package("current")).map(&:retained) == [true]

# The walk reported a rebuild-only tag of the installed version. Skipping the
# walk must not hide that the installed bottle's rebuild is unknown.
notes = result.diagnostics.select { |entry| entry.fetch(:status) == "unknown_installed_build" }
raise "Rebuild uncertainty was lost or invented: #{notes}" unless notes.map { |entry| entry.fetch(:package).fetch(:name) } == ["repackaged"]
note = notes.first
raise "Rebuild diagnostic lost its evidence" unless note.fetch(:tag) == "2.0.0_1-2" && note.fetch(:reason).include?("registry rebuild 2") &&
  note.fetch(:recovery).any?

# A withdrawal or a failed read belongs to its own package. The rest of the
# scope is still assessed, and the failed package never reaches the registry.
withdrawn = BrewCooldown::HomebrewAdapter::RegistryError.new("Homebrew has disabled current: upstream security withdrawal")
result, registry, = discover(records, current.merge("current" => withdrawn))
raise "Withdrawal was not reported for its package" unless result.errors.length == 1 &&
  result.errors.first.fetch(:package).fetch(:name) == "current" && result.errors.first.fetch(:error).include?("security withdrawal")
raise "A withdrawn formula reached the registry" if registry.walked.include?("current")
raise "One failed read stopped the other packages" unless registry.walked.sort == %w[ahead behind rescheme revised]

# A dependency that only a candidate introduces is outside the batch. It is
# read on its own when the walk reaches it instead of being skipped or guessed.
result, registry, metadata = discover(records, current, batch_omits: ["behind"])
raise "A package outside the batch was not read individually: #{metadata.single}" unless metadata.single == ["behind"]
raise "A package outside the batch skipped its registry walk" unless registry.walked.include?("behind") && result.errors.empty?
puts "PASS: installed current builds skip the registry, keep rebuild diagnostics and isolate failed reads"
