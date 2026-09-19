# frozen_string_literal: true

require "tmpdir"
require "digest"
require_relative "../../lib/brew_cooldown/policy"
require_relative "../../lib/brew_cooldown/observations"

def expect_error(fragment)
  yield
  raise "Expected state error containing #{fragment}"
rescue BrewCooldown::StateError => error
  raise unless error.message.include?(fragment)
end

Dir.mktmpdir("cooldown-observations-") do |directory|
  package = BrewCooldown::PackageId.new(kind: :formula, tap: "homebrew/core", name: "example")
  build = BrewCooldown::Build.new(version: "1.2.3", revision: 0, rebuild: 0, scheme: 0)
  release = BrewCooldown::Release.new(package:, build:, identity: Digest::SHA256.hexdigest("first artifact"),
                        verified: true, published_at: nil, publication_source: nil)
  first = Time.iso8601("2026-09-01T00:30:00.123456789Z")
  wall_time = first
  clock = -> { wall_time.getlocal("-07:00") }
  ledger = BrewCooldown::Observations.new(directory, prefix: directory, clock:)
  observed = ledger.first_seen(release, now: first.getlocal("-07:00"))
  raise "Observation used local calendar time" unless observed == first

  # Restarting the process or losing upstream caches must not reset this wait.
  ledger = BrewCooldown::Observations.new(directory, prefix: directory, clock:)
  later = first + 14 * 86_400
  wall_time = later
  raise "Restart reset first observation" unless ledger.first_seen(release, now: later) == first

  # The version is unchanged; changed bytes must still receive a new clock.
  changed = release.with(identity: Digest::SHA256.hexdigest("replacement artifact"))
  raise "Moved tag inherited another artifact's age" unless ledger.first_seen(changed, now: later) == later
  expect_error("without a verified") { ledger.first_seen(release.with(verified: false), now: later) }
  path = File.join(directory, "observations.json")
  before = File.binread(path)

  # Replay the interleaving without scheduler timing: the later invocation
  # has already persisted, then the earlier one reaches the same ledger.
  overlapping = BrewCooldown::Observations.new(directory, prefix: directory, clock:)
  overlapping.remember_clock(now: first)
  raise "Overlapping invocation lowered the clock floor" unless File.binread(path) == before
  raise "Overlap reset an existing wait" unless overlapping.first_seen(release, now: first) == first
  unseen = release.with(identity: Digest::SHA256.hexdigest("overlapping artifact"))
  raise "Overlap backdated a new wait" unless overlapping.first_seen(unseen, now: first) == later
  persisted = JSON.parse(File.read(path))
  raise "Clamped observation was not persisted" unless Time.iso8601(persisted.fetch("observed").fetch(unseen.identity)) == later
  wall_time = later + 1
  overlapping.remember_clock(now: first)
  raise "Overlap advanced the frozen clock floor" unless Time.iso8601(JSON.parse(File.read(path)).fetch("last_seen")) == later

  # A frozen timestamp ahead of the floor must not hide an actual rollback.
  before = File.binread(path)
  wall_time = later - Rational(1, 1_000_000_000)
  expect_error("clock moved backward") { ledger.remember_clock(now: later + 1) }
  expect_error("clock moved backward") { ledger.remember_clock(now: first) }
  expect_error("clock moved backward") do
    ledger.first_seen(release.with(identity: Digest::SHA256.hexdigest("regressed artifact")), now: first)
  end
  raise "Regressed clock overwrote durable state" unless File.binread(path) == before
  wall_time = later

  File.write(path, '{"schema":999}')
  expect_error("unsupported or mismatched") { ledger.remember_clock(now: later) }
  raise "Unsupported state was deleted" unless File.read(path) == '{"schema":999}'
  File.write(path, "{")
  expect_error("cannot read observation state") { ledger.remember_clock(now: later) }
  raise "Malformed state was deleted" unless File.read(path) == "{"

  File.unlink(path)
  raise "Loss of state did not restart conservative wait" unless ledger.first_seen(release, now: later) == later
end
puts "PASS: durable candidate clocks, overlap, changed identity, restart, clock regression and malformed state"
