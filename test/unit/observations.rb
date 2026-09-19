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
  ledger = BrewCooldown::Observations.new(directory, prefix: directory)
  observed = ledger.first_seen(release, now: first.getlocal("-07:00"))
  raise "Observation used local calendar time" unless observed == first

  # Restarting the process or losing upstream caches must not reset this wait.
  ledger = BrewCooldown::Observations.new(directory, prefix: directory)
  later = first + 14 * 86_400
  raise "Restart reset first observation" unless ledger.first_seen(release, now: later) == first

  # The version is unchanged; changed bytes must still receive a new clock.
  changed = release.with(identity: Digest::SHA256.hexdigest("replacement artifact"))
  raise "Moved tag inherited another artifact's age" unless ledger.first_seen(changed, now: later) == later
  expect_error("without a verified") { ledger.first_seen(release.with(verified: false), now: later) }
  path = File.join(directory, "observations.json")
  before = File.binread(path)
  expect_error("clock moved backward") { ledger.remember_clock(now: first) }
  raise "Regressed clock overwrote durable state" unless File.binread(path) == before

  File.write(path, '{"schema":999}')
  expect_error("unsupported or mismatched") { ledger.remember_clock(now: later) }
  raise "Unsupported state was deleted" unless File.read(path) == '{"schema":999}'
  File.write(path, "{")
  expect_error("cannot read observation state") { ledger.remember_clock(now: later) }
  raise "Malformed state was deleted" unless File.read(path) == "{"

  File.unlink(path)
  raise "Loss of state did not restart conservative wait" unless ledger.first_seen(release, now: later) == later
end
puts "PASS: durable candidate clocks, changed identity, restart, clock regression and malformed state"
