# frozen_string_literal: true

require "open3"

abort "Run only in an expendable VM" unless ENV["HOMEBREW_COOLDOWN_DISPOSABLE"] == "1"
require_relative "../../prototype/execution"
BrewCooldown::Prototype::Execution.check_homebrew!

phase = ARGV.fetch(0)
state = Pathname(ENV.fetch("HOMEBREW_COOLDOWN_TEST_STATE"))
if phase == "crash_check"
  target = ARGV.fetch(1)
  raise "Unknown interruption target" unless %w[interrupt interrupt_started].include?(target)
  output, status = Open3.capture2e(HOMEBREW_BREW_FILE.to_s, "ruby", "--", __FILE__, target)
  puts output
  raise "Child did not terminate by SIGKILL: #{status}" unless status.signaled? && status.termsig == Signal.list.fetch("KILL")
  puts "PASS: child terminated by SIGKILL at #{target}"
  exit
end

if %w[reconcile unconfirmed].include?(phase)
  journal = BrewCooldown::Prototype::Journal.new(state)
  before = BrewCooldown::Prototype::Inventory.capture
  expected = phase == "unconfirmed" ? "unconfirmed" : "completed"
  journal.with_lock do
    report = journal.report
    states = report.fetch("operations").to_h { |entry| [entry.fetch("name"), entry.fetch("status")] }
    raise "Misreported dependency progress" unless states.fetch("pcre2") == expected
    raise "Misreported unstarted root" unless states.fetch("ripgrep") == "pending"
    raise "Recovery output missing" unless report.fetch("operations").all? { |entry| entry.fetch("recovery").any? }
    puts JSON.pretty_generate(report)
  end
  raise "Reconciliation changed installed packages" unless BrewCooldown::Prototype::Inventory.capture == before
  puts "PASS: interruption reconciled with #{expected} and pending work, text-only recovery"
  exit
end

if phase == "accept"
  journal = BrewCooldown::Prototype::Journal.new(state)
  before = BrewCooldown::Prototype::Inventory.capture
  journal.with_lock do
    journal.load
    puts JSON.pretty_generate(journal.accept_current(expected_inventory: before))
  end
  raise "Acceptance changed packages" unless BrewCooldown::Prototype::Inventory.capture == before
  raise "Accepted journal retained" if journal.path.exist?
  puts "PASS: explicit acceptance cleared the journal without package mutation"
  exit
end

records = JSON.parse(File.read(File.join(__dir__, "candidates.json"))).fetch("upgrade")
candidates = records.map do |record|
  formula_path = HOMEBREW_PREFIX/"opt"/record.fetch("name")
  if phase == "resume" && formula_path.exist? && Keg.new(formula_path.realpath).version.to_s == record.fetch("version")
    BrewCooldown::Prototype::Retained.new(Keg.new(formula_path.realpath))
  else
    BrewCooldown::Prototype::Candidate.new(record).prepare
  end
end
map = BrewCooldown::Prototype::ExactMap.new(candidates)
map.activate
execution = BrewCooldown::Prototype::Execution.new(map, state_directory: state)
inventory = BrewCooldown::Prototype::Inventory.capture

case phase
when "drift"
  raise "Pin already exists" if (HOMEBREW_PINNED_KEGS/"pcre2").symlink?
  output, status = Open3.capture2e(HOMEBREW_BREW_FILE.to_s, "pin", "pcre2")
  raise "Could not inject actual pin drift: #{output}" unless status.success?
  begin
    changed = BrewCooldown::Prototype::Inventory.capture
    result = execution.apply(expected_inventory: inventory)
    raise "Drift was not reported: #{result}" unless result.fetch("status") == "drift"
    raise "Drift mutated packages" unless changed == BrewCooldown::Prototype::Inventory.capture
    raise "Drift omitted recovery commands" unless result.fetch("recovery").fetch("pcre2").any?
    puts JSON.pretty_generate(result)
    puts "PASS: pin drift detected before mutation, with recovery commands"
  ensure
    output, status = Open3.capture2e(HOMEBREW_BREW_FILE.to_s, "unpin", "pcre2")
    raise "Could not remove experiment pin: #{output}" unless status.success?
  end
when "interrupt", "interrupt_started"
  # Killing after a durable boundary leaves a real changed prefix and journal
  # for a fresh process to inspect; no fake installer result can satisfy it.
  stop_at = phase == "interrupt" ? "completed" : "started"
  execution.apply(expected_inventory: inventory) do |name, status|
    Process.kill("KILL", Process.pid) if name == "pcre2" && status == stop_at
  end
  raise "Interruption point was not reached"
when "complete", "resume"
  result = execution.apply(expected_inventory: inventory)
  puts JSON.pretty_generate(result)
  raise "Execution did not complete" unless result.fetch("status") == "completed"
  raise "Completed journal was retained" if execution.journal.path.exist?
  output, status = Open3.capture2((HOMEBREW_PREFIX/"opt/ripgrep/bin/rg").to_s,
                                "--pcre2", "a(?=b)", stdin_data: "ab\n")
  raise "Installed runtime failed" unless status.success? && output == "ab\n"
  puts "PASS: native component execution and completed journal cleanup"
else
  raise "Unknown phase #{phase}"
end
