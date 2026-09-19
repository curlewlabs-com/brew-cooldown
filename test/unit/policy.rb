# frozen_string_literal: true

require "time"
require "digest"
require_relative "../../lib/brew_cooldown/policy"
require_relative "../../lib/brew_cooldown/homebrew/build_order"

def assert_equal(expected, actual, reason)
  raise "#{reason}: expected #{expected.inspect}, got #{actual.inspect}" unless expected == actual
end

def build(version, revision: 0, rebuild: 0, scheme: 0)
  BrewCooldown::Build.new(version:, revision:, rebuild:, scheme:)
end

package = BrewCooldown::PackageId.new(kind: :formula, tap: "homebrew/core", name: "example")
origin = Time.iso8601("2026-08-01T00:30:00Z")
installed = BrewCooldown::Installed.new(package:, build: build("1.2.0"), pinned: false)
release = BrewCooldown::Release.new(package:, build: build("1.2.1"), identity: Digest::SHA256.hexdigest("candidate-a"),
                      verified: true, published_at: origin, publication_source: :platform_manifest)
unknown = BrewCooldown::SecurityEvidence.new(installed_affected: nil, candidate_affected: nil,
                               fixed_advisories: [], validated_at: nil)
policy = BrewCooldown::Policy.new(compare_builds: BrewCooldown::HomebrewAdapter::BuildOrder)
evaluate = lambda do |candidate = release, baseline = installed, **options|
  policy.evaluate(release: candidate, installed: baseline, now: origin + 14 * 86_400,
                  security: unknown, **options)
end

# A local date differing from UTC must not postpone an elapsed-time boundary.
equality = origin + 14 * 86_400
assert_equal(:cooldown, evaluate.call(now: equality - 1).status, "one second before eligibility")
assert_equal(:eligible, evaluate.call(now: equality).status, "exact eligibility boundary")
assert_equal(evaluate.call(now: equality), evaluate.call(now: equality.getlocal("-07:00")), "UTC/local date disagreement")
spring = Time.iso8601("2026-03-01T09:30:00Z")
assert_equal(:eligible, evaluate.call(release.with(published_at: spring), now: spring + 14 * 86_400).status,
             "daylight-saving transition does not change elapsed days")

[
  ["1.2.2", :patch, 14], ["1.3.0", :minor, 21], ["2.0.0", :major, 60],
  ["2.0.0-rc1", :default, 14]
].each do |version, kind, days|
  result = evaluate.call(release.with(build: build(version)))
  assert_equal(kind, result.delay_kind, "release classification for #{version}")
  assert_equal(origin + days * 86_400, result.eligible_at, "delay for #{version}")
end
[
  [build("0.1.0"), build("0.2.0")], [build("2026-08-01"), build("2026-09-01")],
  [build("1.2.0"), build("1.2.0", revision: 1)],
  [build("1.2.0"), build("1.2.0", rebuild: 1)],
  [build("1.2.0"), build("1.2.1", scheme: 1)]
].each do |before, after|
  result = evaluate.call(release.with(build: after), installed.with(build: before))
  assert_equal(:default, result.delay_kind, "non-semantic or package-only changes use fallback")
end
assert_equal(:default, evaluate.call(release, nil).delay_kind, "new dependency has no semantic baseline")
assert_equal(:not_newer, evaluate.call(release.with(build: build("1.1.9"))).status, "never downgrade")
assert_equal(:not_newer, evaluate.call(release.with(build: installed.build)).status, "do not reinstall unchanged build")
assert_equal(:unknown_installed_build,
             evaluate.call(release.with(build: installed.build.with(rebuild: 1)), installed.with(build: installed.build.with(rebuild: nil))).status,
             "missing installed rebuild is not evidence of rebuild zero")

# Publication churn adds options without resetting an older candidate's clock.
releases = (1..30).map do |patch|
  release.with(build: build("1.2.#{patch}"), published_at: origin + (patch - 1) * 86_400,
               identity: Digest::SHA256.hexdigest("candidate-#{patch}"))
end
eligible = releases.select { |candidate| evaluate.call(candidate).eligible? }
assert_equal(["1.2.1"], eligible.map { |candidate| candidate.build.version }, "daily releases cannot starve a mature candidate")
assert_equal(evaluate.call(releases.first).eligible_at, evaluate.call(releases.first, now: equality + 86_400).eligible_at,
             "later invocation preserves the candidate's boundary")

undated = release.with(published_at: nil, publication_source: nil)
assert_equal(:needs_observation, evaluate.call(undated).status, "missing date starts a wait instead of looking old")
assert_equal(:eligible, evaluate.call(undated, first_seen: origin).status, "verified first observation eventually matures")
assert_equal(:cooldown, evaluate.call(undated.with(identity: Digest::SHA256.hexdigest("replacement")), first_seen: equality).status,
             "replacement bytes receive their own observation clock")
assert_equal(:unverified, evaluate.call(release.with(verified: false)).status, "identity is required even for old releases")
assert_equal(:invalid_time, evaluate.call(release.with(published_at: equality + 1)).status, "future-dated publication")
assert_equal(:clock_regression, evaluate.call(clock_floor: equality + 1).status, "clock regression blocks advancement")

fixed = BrewCooldown::SecurityEvidence.new(installed_affected: true, candidate_affected: false,
                             fixed_advisories: ["BREW-example"], validated_at: origin)
assert_equal(:security_fix, evaluate.call(now: origin, security: fixed).status, "explicit fix can bypass age")
assert_equal(:pinned, evaluate.call(release, installed.with(pinned: true), now: origin, security: fixed).status,
             "security fixes respect user pins")
assert_equal(:affected, evaluate.call(security: fixed.with(candidate_affected: true)).status,
             "stale adverse evidence still excludes affected candidates")
assert_equal(:cooldown, evaluate.call(now: origin + 3601, security: fixed).status, "stale refresh cannot expedite")
assert_equal(:security_fix, evaluate.call(now: origin + 3600, security: fixed).status, "freshness equality")
assert_equal(:cooldown, evaluate.call(now: origin, security: fixed.with(fixed_advisories: [])).status,
             "affected installation alone is not evidence of a fixed candidate")
assert_equal(:cooldown, evaluate.call(now: origin, security: fixed.with(candidate_affected: nil)).status,
             "unknown candidate security state cannot authorize bypass")
assert_equal(:cooldown, evaluate.call(release, nil, now: origin, security: fixed).status,
             "a young dependency cannot inherit its parent's security exception")
assert_equal(:eligible, evaluate.call(security: unknown).status, "missing feed permits mature routine upgrades")

begin
  evaluate.call(release.with(package: package.with(kind: :cask)))
  raise "Formula/cask collision accepted"
rescue ArgumentError => error
  raise unless error.message.include?("identities differ")
end
begin
  BrewCooldown::Policy.new(compare_builds: BrewCooldown::HomebrewAdapter::BuildOrder, delays: { patch: -1 })
  raise "Negative cooldown accepted"
rescue ArgumentError => error
  raise unless error.message.include?("nonnegative integers")
end
puts "PASS: elapsed cooldowns, candidate churn, fallback observations, pins and security eligibility"
