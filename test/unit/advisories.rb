# frozen_string_literal: true

require "json"
require "time"
require "digest"
require "tmpdir"
require_relative "../../lib/brew_cooldown/homebrew/advisories"
require_relative "../../lib/brew_cooldown/homebrew/build_order"

FIXTURE = JSON.parse(File.read(File.expand_path("../fixtures/advisories.json", __dir__))).fetch("advisories")
NOW = Time.iso8601("2026-09-18T00:30:00Z")

def changed_record
  record = Marshal.load(Marshal.dump(FIXTURE.fetch("git").first))
  yield record
  record
end

def assess(records: FIXTURE, name: "git", before: "2.54.0", after: "2.55.0", revision: 0,
           fresh: true, kind: :formula, tap: "homebrew/core", **options)
  package = BrewCooldown::PackageId.new(kind:, tap:, name:)
  build = BrewCooldown::Build.new(version: before, revision: 0, rebuild: 0, scheme: 0)
  installed = BrewCooldown::Installed.new(package:, build:, pinned: false)
  release = BrewCooldown::Release.new(package:, build: build.with(version: after, revision:),
                                      verified: true, identity: Digest::SHA256.hexdigest(after),
                                      published_at: NOW, publication_source: :platform_manifest)
  adapter = BrewCooldown::HomebrewAdapter::Advisories.new(records:, validated_at: fresh ? NOW : nil)
  assessment = adapter.assess(release:, installed:, **options)
  decision = BrewCooldown::Policy.new(compare_builds: BrewCooldown::HomebrewAdapter::BuildOrder)
                                .evaluate(release:, installed:, now: NOW, security: assessment.evidence)
  [assessment, decision]
end

def expect(expected, actual, reason)
  raise "#{reason}: expected #{expected.inspect}, got #{actual.inspect}" unless expected == actual
end

assessment, decision = assess
expect(:security_fix, decision.status, "recorded explicit Homebrew fix")
expect(["BREW-git-CVE-2025-40918"], assessment.evidence.fixed_advisories, "same-record attribution")
expect(:security_fix, assess(name: "python@3.14", before: "3.14.0", after: "3.14.0", revision: 1).last.status,
       "Homebrew formula revision is part of the fixed boundary")
expect(:affected, assess(after: "2.54.1").last.status, "candidate is still affected")
expect(:cooldown, assess(fresh: false).last.status, "stale cache cannot expedite")
expect(:affected, assess(after: "2.54.1", fresh: false).last.status, "stale adverse evidence survives")
expect(:no_records, assess(name: "no-coverage").first.coverage, "missing coverage remains explicit")
expect(nil, assess(name: "no-coverage").first.evidence.candidate_affected, "absence is not a clean scan")
expect(:unsupported_package, assess(kind: :cask).first.coverage, "formula and cask identity separation")
expect(:unsupported_package, assess(tap: "someone/else").first.coverage, "tap identity separation")

withdrawn = changed_record { |row| row["withdrawn"] = "2026-09-17T00:00:00Z" }
expect(:no_records, assess(records: { "git" => [withdrawn] }).first.coverage, "withdrawn evidence is excluded")

# A range endpoint is not necessarily a statement that a release fixes anything.
%w[limit last_affected].each do |terminal|
  record = changed_record do |row|
    row["affected"][0]["ranges"][0]["events"][-1] = { terminal => "2.54.9" }
  end
  expect(:cooldown, assess(records: { "git" => [record] }).last.status, "#{terminal} cannot authorize a fix")
end

mutations = [
  ->(row) { row["schema_version"] = "2.0.0" },
  ->(row) { row["id"] = nil },
  ->(row) { row["withdrawn"] = "2026-02-31T00:00:00Z" },
  ->(row) { row["affected"] = "invalid" },
  ->(row) { row["affected"][0]["package"]["ecosystem"] = "other" },
  ->(row) { row["affected"][0]["versions"] = [1] },
  ->(row) { row["affected"][0]["ranges"][0]["type"] = "FUTURE" },
  ->(row) { row["affected"][0]["ranges"][0]["type"] = "GIT" },
  ->(row) { row["affected"][0]["ranges"][0]["events"] = [{ "fixed" => "2.55.0" }] },
  ->(row) { row["affected"][0]["ranges"][0]["events"] = [{ "introduced" => "3.0.0" }, { "fixed" => "2.55.0" }] },
  ->(row) { row["affected"][0]["ranges"][0]["events"][-1]["limit"] = "2.55.0" },
  ->(row) { row["affected"][0]["ranges"][0]["events"][-1]["fixed"] = 255 },
]
mutations.each do |mutation|
  row = changed_record(&mutation)
  result, outcome = assess(records: { "git" => [row] })
  expect(:incomplete, result.coverage, "invalid or unsupported evidence")
  expect(:cooldown, outcome.status, "invalid evidence cannot bypass age")
  raise "Unknown evidence lacks explanation" if result.advisories.first.reason.to_s.empty?
end

# Partial support must retain adverse evidence within the same record and
# across records, while never promoting a partial scan to clean evidence.
partial = changed_record do |row|
  row["affected"][0]["ranges"] << { "type" => "FUTURE", "events" => [{ "introduced" => "0" }] }
end
expect(:affected, assess(records: { "git" => [partial] }, after: "2.54.1").last.status, "partial record's known affected range")
expect(:cooldown, assess(records: { "git" => [partial] }).last.status, "partial negative evidence")
ongoing = changed_record do |row|
  row["id"] = "BREW-git-another"
  row["affected"][0]["ranges"][0]["events"] = [{ "introduced" => "0" }]
end
expect(:affected, assess(records: { "git" => [FIXTURE["git"][0], ongoing, partial] }).last.status,
       "another advisory still affects the candidate")

patch = changed_record { |row| row["affected"][0]["ecosystem_specific"]["fix"] = "patch" }
expect(:cooldown, assess(records: { "git" => [patch] }).last.status, "today's patch annotation is not historical evidence")
expect(:security_fix, assess(records: { "git" => [patch] }, candidate_patches: ["CVE-2025-40918"]).last.status,
       "verified recipe patch attribution")
expect(:cooldown, assess(records: { "git" => [patch] }, candidate_patches: ["CVE-unrelated"]).last.status,
       "unrelated patch cannot authorize bypass")
patch["upstream"] << "CVE-another"
expect(:cooldown, assess(records: { "git" => [patch] }, candidate_patches: ["CVE-2025-40918"]).last.status,
       "directed upstream references are not interchangeable aliases")

semver = changed_record { |row| row["affected"][0]["ranges"][0]["type"] = "SEMVER" }
expect(:security_fix, assess(records: { "git" => [semver] }).last.status, "native semantic comparison")
expect(:affected, assess(records: { "git" => [semver] }, after: "2.55.0-rc1").last.status,
       "prerelease is not the stable fix")
uncomparable, decision = assess(records: { "git" => [semver] }, after: "nonsense")
expect(nil, uncomparable.evidence.candidate_affected, "uncomparable semantic candidate is unknown")
raise "Uncomparable version authorized" if decision.eligible?

# The native cache remains the data owner during an outage. Only the network
# call is replaced here; cache parsing, fallback and policy assessment are real.
Dir.mktmpdir("cooldown-advisories-") do |directory|
  path = Pathname(directory)/"advisories.json"
  path.write(JSON.generate("advisories" => FIXTURE))
  events = []
  log = ->(**event) { events << event }
  outage = ->(_path) { raise Homebrew::Vulns::CachedFeed::Error, "upstream unavailable" }
  adapter = BrewCooldown::HomebrewAdapter::Advisories.refresh(now: NOW, log:, cache: directory, fetch: outage)
  package = BrewCooldown::PackageId.new(kind: :formula, tap: "homebrew/core", name: "git")
  build = BrewCooldown::Build.new(version: "2.54.0", revision: 0, rebuild: 0, scheme: 0)
  installed = BrewCooldown::Installed.new(package:, build:, pinned: false)
  release = BrewCooldown::Release.new(package:, build: build.with(version: "2.54.1"), identity: nil,
                                      verified: false, published_at: nil, publication_source: nil)
  evidence = adapter.assess(release:, installed:).evidence
  expect(nil, evidence.validated_at, "cache fallback never receives successful-refresh timestamp")
  expect(true, evidence.candidate_affected, "actual cache fallback keeps adverse evidence")
  raise "Refresh error was silent" unless events.any? { |event| event[:error] == "upstream unavailable" }

  path.write("{")
  adapter = BrewCooldown::HomebrewAdapter::Advisories.refresh(now: NOW, log:, cache: directory, fetch: outage)
  expect(:no_records, adapter.assess(release:, installed:).coverage, "unreadable cache yields unknown coverage")
  raise "Cache error was silent" unless events.any? { |event| event[:operation] == "read_cached_advisories" }
  expect("{", path.read, "failed reads preserve native cache")
end

puts "PASS: recorded fixes, revisions, freshness, withdrawal, partial evidence, patch proof and unknown coverage"
