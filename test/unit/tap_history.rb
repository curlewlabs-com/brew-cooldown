# frozen_string_literal: true

require "tmpdir"
require_relative "../../lib/brew_cooldown/planning"
require_relative "../../lib/brew_cooldown/homebrew/tap_evidence"

include BrewCooldown
NOW = Time.iso8601("2026-10-08T06:30:00Z")
FIXTURE = JSON.parse(File.read(File.join(__dir__, "../fixtures/tap_history.json")))
PACKAGE = PackageId.new(kind: :formula, tap: "openai/tools", name: "tart")

# GitHub responses recorded on 2026-10-08 from openai/homebrew-tools and the
# named release repositories; only consumed fields and formula tree rows kept.
# Native Ruby recipe evaluation, policy and planner remain real.
class RecordedTapHistory < HomebrewAdapter::TapHistory
  def initialize(package:, fixture: FIXTURE, **options)
    @fixture = fixture
    super(package:, **options, request: method(:response))
  end

  def response(url)
    uri = URI(url)
    query = URI.decode_www_form(uri.query || "").to_h
    rows = @fixture.fetch("packages").fetch(package.name)
    case uri.path
    when %r{/releases/tags/} then rows.fetch("releases").fetch(uri.path.split("/").last)
    when %r{/contents/} then rows.fetch("contents").fetch(query.fetch("ref"))
    when %r{/git/trees/} then @fixture.fetch("tree")
    when %r{/commits/} then { "sha" => @fixture.fetch("head") }
    when %r{/commits\z}
      raise "Unanchored history" unless query.fetch("sha") == @fixture.fetch("head") && query.fetch("path") == path
      rows.fetch("commits")
    else @fixture.fetch("repository")
    end
  end

  def candidate(entry)
    record = source_record(entry)
    content = @fixture.fetch("packages").fetch(package.name).fetch("contents").fetch(entry.commit)
    bytes = content.fetch("content").delete("\n").unpack1("m0")
    Executor::TapCandidate.new(record).send(:evaluate_recipe, bytes, path: Pathname("/recorded/#{entry.commit}/#{package.name}.rb"))
  end
end

def refuses(fragment)
  yield
rescue StandardError => error
  raise unless error.message.include?(fragment)
  return
else
  raise "Expected refusal containing #{fragment}"
end

history = RecordedTapHistory.new(package: PACKAGE, log: ->(**_event) {}, now: NOW).refresh
entries = history.entries.to_a
latest = history.candidate(entries.first)
eligible = history.candidate(entries.fetch(2))
baseline = Installed.new(package: PACKAGE, build: history.candidate(entries.fetch(3)).build.with(rebuild: nil), pinned: false)
raise "Wrong recorded recipe" unless latest.formula.version.to_s == "2.40.1" && eligible.formula.version.to_s == "2.37.0"
latest.verify_shape!
eligible.verify_shape!
raise "Historical hook was lost" unless eligible.formula.post_install_defined?
raise "Runtime dependency was lost" unless eligible.formula.deps.map(&:name) == ["openai/tools/softnet"]
raise "Historical recipe provenance was lost" unless eligible.formula.tap_git_head == entries.fetch(2).commit

# Recipe and artifact ages differ. The recipe cannot inherit the earlier
# vendor clock, and a changed asset cannot inherit the earlier recipe clock.
publication = history.publication(eligible, entries.fetch(2))
raise "Recipe publication was ignored" unless publication == Time.iso8601("2026-09-09T22:22:43Z")
mutated = Marshal.load(Marshal.dump(FIXTURE))
asset = mutated.fetch("packages").fetch("tart").fetch("releases").fetch("2.37.0").fetch("assets").first
asset["updated_at"] = "2026-10-07T01:00:00Z"
changed = RecordedTapHistory.new(package: PACKAGE, fixture: mutated, log: ->(**_event) {}, now: NOW)
raise "Changed asset borrowed old age" unless changed.publication(eligible, entries.fetch(2)) == Time.iso8601(asset["updated_at"])
asset.delete("updated_at")
raise "Missing artifact date invented publication" unless changed.publication(eligible, entries.fetch(2)).nil?
asset["digest"] = "sha256:#{'0' * 64}"
refuses("digest differs") { changed.publication(eligible, entries.fetch(2)) }

security = SecurityEvidence.new(installed_affected: nil, candidate_affected: nil, fixed_advisories: [], validated_at: nil)
policy = Policy.new(compare_builds: HomebrewAdapter::BuildOrder)
old_release = HomebrewAdapter::TapEvidence.release(PACKAGE, eligible, published_at: publication)
new_release = HomebrewAdapter::TapEvidence.release(PACKAGE, latest, published_at: history.publication(latest, entries.first))
old_decision = policy.evaluate(release: old_release, installed: baseline, now: NOW, security:)
new_decision = policy.evaluate(release: new_release, installed: baseline, now: NOW, security:)
raise "Older eligible release was hidden by latest" unless old_decision.eligible? && new_decision.status == :cooldown
raise "Local date test lost its boundary" unless NOW.getlocal("-07:00").to_date != NOW.utc.to_date
Dir.mktmpdir("cooldown-trusted-observation-") do |directory|
  observations = Observations.new(directory, prefix: directory, clock: -> { NOW })
  undated = old_release.with(published_at: nil, publication_source: nil)
  first_seen = observations.first_seen(undated, now: NOW)
  raise "Undated release installed immediately" unless policy.evaluate(release: undated, installed: baseline, now: NOW, security:, first_seen:).status == :cooldown
  raise "Verified observation did not finish cooldown" unless policy.evaluate(release: undated, installed: baseline, now: NOW + 21 * 86_400, security:, first_seen:).eligible?
end

# Availability requirements must not confer cooldown eligibility. An absent
# dependency with only cooling candidates blocks Tart, while a retained one
# permits the historical upgrade and keeps its own installation.
softnet = PACKAGE.with(name: "softnet")
softnet_history = RecordedTapHistory.new(package: softnet, log: ->(**_event) {}, now: NOW).refresh
softnet_candidate = softnet_history.candidate(softnet_history.entries.first)
softnet_release = HomebrewAdapter::TapEvidence.release(softnet, softnet_candidate, published_at: Time.iso8601("2026-10-01T16:21:22Z"))
softnet_decision = policy.evaluate(release: softnet_release, installed: nil, now: NOW, security:)
root = BrewCooldown::Option.new(release: old_release, decision: old_decision, dependencies: [RuntimeRequirement.new(package: softnet)], compatibility_version: nil, retained: false)
dep = BrewCooldown::Option.new(release: softnet_release, decision: softnet_decision, dependencies: [], compatibility_version: nil, retained: false)
planner = Planner.new(compare_builds: HomebrewAdapter::BuildOrder, compatible: HomebrewAdapter::Compatibility)
raise "Dependency bypassed its cooldown" unless planner.plan(domains: { PACKAGE => [root], softnet => [dep] }, roots: [PACKAGE]).first.status == :no_compatible_solution
kept = dep.with(retained: true)
selection = planner.plan(domains: { PACKAGE => [root], softnet => [dep, kept] }, roots: [PACKAGE]).first.selected
raise "Compatible retained dependency was replaced" unless selection.fetch(softnet).retained && !selection.fetch(PACKAGE).retained

# Pinning unsupported packages intentionally retains them without requesting a
# historical executor. Untrusted unpinned packages must still fail assessment.
record = HomebrewAdapter::InstalledRecord.new(installed: baseline, dependencies: [], compatibility_version: nil, retained: nil, receipt: "receipt", identity: "installed")
config = Config.new({}, directory: Pathname.pwd)
planning = Planning.new(config:, scope: {}, now: NOW, log: ->(**_event) {}, state_directory: Pathname.pwd)
entry = HomebrewAdapter::ScopeEntry.new(kind: :formula, name: "openai/tools/tart", options: {})
inventory = HomebrewAdapter::InventoryResult.new(records: { PACKAGE => record }, errors: [], fingerprint: {})
raise "Untrusted package accepted" unless planning.send(:resolve_entry, entry, inventory).fetch(:status) == :unsupported_executor
pinned = inventory.with(records: { PACKAGE => record.with(installed: baseline.with(pinned: true)) })
raise "Pin required historical executor" unless planning.send(:resolve_entry, entry, pinned).fetch(:status) == :pinned
trusted = Config.new({ "trusted_taps" => ["openai/tools"] }, directory: Pathname.pwd)
planning = Planning.new(config: trusted, scope: {}, now: NOW, log: ->(**_event) {}, state_directory: Pathname.pwd)
raise "Trusted package refused" unless planning.send(:resolve_entry, entry, inventory).fetch(:status) == :selected

corrupt = Marshal.load(Marshal.dump(FIXTURE))
corrupt.fetch("packages").fetch("tart").fetch("contents").fetch(entries.first.commit)["content"] = ["changed recipe"].pack("m0")
refuses("blob differs") do
  RecordedTapHistory.new(package: PACKAGE, fixture: corrupt, log: ->(**_event) {}, now: NOW).refresh.source_record(entries.first)
end
truncated = FIXTURE.merge("tree" => FIXTURE.fetch("tree").merge("truncated" => true))
refuses("tree is incomplete") { RecordedTapHistory.new(package: PACKAGE, fixture: truncated, log: ->(**_event) {}, now: NOW).refresh }
# A refreshed rollback bound cannot re-authorize the selected higher release.
rolled_back = history.dup
rolled_back.instance_variable_set(:@current, eligible)
refuses("possible rollback") { rolled_back.verify_candidate!(latest) }
puts "PASS: trusted history, exact source, release age, pins, dependency cooldowns and actionable refusals"

# Only payload preparation is replaced here; these recorded-response checks
# exercise the production discovery walk and dependency planner, and make no
# claim about artifact verification or native installation (the VM track does).
class PlanningTapHistory < RecordedTapHistory
  def candidate(entry)
    loaded = super
    loaded.define_singleton_method(:prepare) do
      verify_shape!
      @runtime_dependencies = formula.deps.reject(&:test?).map { |dependency| { "full_name" => dependency.name, "runtime_only" => true } }
      self
    end
    loaded
  end
end
original_history = HomebrewAdapter::TapHistory.method(:new)
recorded_history = PlanningTapHistory.method(:new)
begin
  # Unavailable superseded recipes below the installed baseline cannot affect
  # an upgrade assessment. Keep the baseline boundary and advancing evidence.
  bounded_fixture = Marshal.load(Marshal.dump(FIXTURE))
  { "tart" => 3, "softnet" => 2 }.each do |name, baseline_index|
    rows = bounded_fixture.fetch("packages").fetch(name)
    rows.fetch("commits").drop(baseline_index + 1).each { |entry| rows.fetch("contents").delete(entry.fetch("sha")) }
  end
  HomebrewAdapter::TapHistory.define_singleton_method(:new) { |**options| recorded_history.call(**options, fixture: bounded_fixture) }
  Dir.mktmpdir("cooldown-tap-discovery-") do |directory|
    softnet_baseline = Installed.new(package: softnet, build: softnet_history.candidate(softnet_history.entries.to_a.fetch(2)).build.with(rebuild: nil), pinned: false)
    softnet_record = record.with(installed: softnet_baseline, identity: "softnet-installed")
    inventory = inventory.with(records: { PACKAGE => record, softnet => softnet_record })
    result = HomebrewAdapter::Discovery.new(inventory:, config: trusted,
      advisories: HomebrewAdapter::Advisories.new(records: {}, validated_at: NOW),
      observations: Observations.new(directory, prefix: directory, clock: -> { NOW }), now: NOW, log: ->(**_event) {}).collect([PACKAGE, softnet])
    raise "Production tap discovery failed: #{result.errors}" unless result.errors.empty?
    selected = planner.plan(domains: result.domains, roots: [PACKAGE, softnet]).first.selected
    raise "Discovery failed historical selection" unless selected.fetch(PACKAGE).release.build.version == "2.37.0" &&
      selected.fetch(softnet).release.build.version == "0.23.0"
    raise "Discovery erased unsupported advisory coverage" unless result.decisions.all? { |decision| decision.fetch(:security).fetch(:coverage) == :unsupported_package }
    raise "Dependency was omitted from discovered option" unless selected.fetch(PACKAGE).dependencies.map(&:package) == [softnet]

    # A failed release lookup does not stop older evidence from being used,
    # but it must keep the assessment visibly incomplete and actionable.
    HomebrewAdapter::TapHistory.define_singleton_method(:new) do |**options|
      history = recorded_history.call(**options)
      original = history.method(:publication)
      history.define_singleton_method(:publication) do |candidate, entry|
        raise HomebrewAdapter::RegistryError, "Release archive is missing" if candidate.formula.version.to_s == "2.40.1"
        original.call(candidate, entry)
      end
      history
    end
    result = HomebrewAdapter::Discovery.new(inventory:, config: trusted,
      advisories: HomebrewAdapter::Advisories.new(records: {}, validated_at: NOW),
      observations: Observations.new(directory, prefix: directory, clock: -> { NOW }), now: NOW, log: ->(**_event) {}).collect([PACKAGE, softnet])
    raise "Missing artifact was hidden" unless result.errors.one? && result.errors.first.fetch(:recovery).any?
    raise "Missing latest artifact blocked independent historical evidence" unless planner.plan(domains: result.domains, roots: [PACKAGE, softnet]).first.selected.fetch(PACKAGE).release.build.version == "2.37.0"
  end
ensure
  HomebrewAdapter::TapHistory.define_singleton_method(:new, original_history)
end
puts "PASS: production trusted-tap discovery selects historical candidates and preserves evidence failures"

# Native DSL evaluation, rather than a Ruby source matcher, owns rejection of
# unsupported installers. Changed source bytes cannot inherit the old clock.
bytes = FIXTURE.fetch("packages").fetch("tart").fetch("contents").fetch(entries.fetch(2).commit).fetch("content").delete("\n").unpack1("m0")
def changed_recipe(candidate, contents)
  digest = Digest::SHA256.hexdigest(contents)
  record = candidate.record.merge("source_sha256" => digest)
  Executor::TapCandidate.new(record).send(:evaluate_recipe, contents, path: Pathname("/recorded/#{digest}/tart.rb"))
end
[bytes.sub('  sha256 ', '  # sha256 '), bytes.sub('  depends_on "openai/tools/softnet"', '  depends_on "openai/tools/softnet" => :build'),
 bytes.sub('/releases/download/2.37.0/', '/archive/refs/tags/2.37.0/')].each do |unsupported|
  refuses(unsupported.include?("=> :build") ? "unsupported release installer" : "checksum-bound") { changed_recipe(eligible, unsupported).verify_shape! }
end
changed = changed_recipe(eligible, bytes + "\n# Different authenticated recipe bytes.\n")
raise "Changed recipe borrowed candidate age" if HomebrewAdapter::TapEvidence.release(PACKAGE, changed, published_at: publication).identity == old_release.identity
impossible = Marshal.load(Marshal.dump(FIXTURE))
impossible.fetch("packages").fetch("tart").fetch("releases").fetch("2.37.0")["published_at"] = "2026-02-31T00:00:00Z"
raise "Impossible publication date became trusted age" unless RecordedTapHistory.new(package: PACKAGE, fixture: impossible, log: ->(**_event) {}, now: NOW).publication(eligible, entries.fetch(2)).nil?
puts "PASS: unsupported native release shapes and invalid calendar evidence fail closed"

# Homebrew's DSL derives disabled? from the machine's local date. The adapter
# must instead respect its injected UTC assessment date, including scheduled
# withdrawals not active on the machine yet.
future_date = "2099-01-01"
withdrawn = changed_recipe(eligible, bytes.sub('  license ', "  disable! date: \"#{future_date}\", because: \"withdrawn\"\n  license "))
withdrawal_history = history.dup
withdrawal_history.instance_variable_set(:@current, withdrawn)
withdrawal_history.instance_variable_set(:@now, Time.iso8601("2099-01-01T06:30:00Z"))
refuses("currently disables") { withdrawal_history.verify_candidate!(eligible) }
withdrawal_history.instance_variable_set(:@now, Time.iso8601("2098-12-31T23:59:59Z"))
withdrawal_history.verify_candidate!(eligible)
puts "PASS: scheduled tap withdrawal uses the injected UTC date"

require_relative "../../lib/brew_cooldown/homebrew/revalidation"
original_history = HomebrewAdapter::TapHistory.method(:new)
recorded_history = PlanningTapHistory.method(:new)
begin
  HomebrewAdapter::TapHistory.define_singleton_method(:new) { |**options| recorded_history.call(**options) }
  Dir.mktmpdir("cooldown-tap-revalidation-") do |directory|
    revalidation = HomebrewAdapter::Revalidation.new(config: trusted, inventory:, prepared: { old_release.identity => eligible },
      state_directory: directory, log: ->(**_event) {}, clock: -> { NOW })
    refreshed = revalidation.send(:tap_release, PACKAGE, eligible, verify_payload: false)
    raise "Revalidation changed the exact selected identity" unless refreshed.identity == old_release.identity
    untrusted = HomebrewAdapter::Revalidation.new(config:, inventory:, prepared: {},
      state_directory: directory, log: ->(**_event) {}, clock: -> { NOW })
    refuses("no longer explicitly trusted") { untrusted.send(:tap_release, PACKAGE, eligible, verify_payload: false) }

    # A force-pushed tap history cannot retain execution authority merely
    # because a selected commit is still fetchable by its Git object ID.
    HomebrewAdapter::TapHistory.define_singleton_method(:new) do |**options|
      loaded = recorded_history.call(**options)
      entries_method = loaded.method(:entries)
      loaded.define_singleton_method(:entries) { entries_method.call.reject { |entry| entry.commit == eligible.record.fetch("commit") } }
      loaded
    end
    refuses("no longer reachable") { revalidation.send(:tap_release, PACKAGE, eligible, verify_payload: false) }
  end
ensure
  HomebrewAdapter::TapHistory.define_singleton_method(:new, original_history)
end
puts "PASS: trusted release revalidation preserves exact identity and refuses revoked trust or unreachable history"
