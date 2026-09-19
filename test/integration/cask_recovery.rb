# frozen_string_literal: true

require "open3"
require_relative "../../prototype/execution"
require_relative "../../prototype/cask_retained"

abort "Run only in an expendable VM with baseline Codex installed" unless ENV["HOMEBREW_COOLDOWN_DISPOSABLE"] == "1"
BrewCooldown::Prototype::Execution.check_homebrew!
phase = ARGV.fetch(0)
state = Pathname(ENV.fetch("HOMEBREW_COOLDOWN_TEST_STATE"))

if phase == "crash_check"
  boundary = ARGV.fetch(1)
  raise "Unknown interruption boundary" unless %w[started completed].include?(boundary)
  output, status = Open3.capture2e(HOMEBREW_BREW_FILE.to_s, "ruby", "--", __FILE__, "interrupt_#{boundary}")
  puts output
  raise "Child did not terminate by SIGKILL" unless status.signaled? && status.termsig == Signal.list.fetch("KILL")
  journal = BrewCooldown::Prototype::Journal.new(state)
  before = BrewCooldown::Prototype::Inventory.capture
  report = journal.report(observed: before)
  operation = report.fetch("operations").fetch(0)
  expected = boundary == "started" ? "unconfirmed" : "completed"
  raise "Wrong cask interruption state" unless operation.fetch("kind") == "cask" && operation.fetch("status") == expected
  raise "Cask recovery commands missing" unless operation.fetch("recovery").all? { |entry| entry.fetch("command").include?("--cask") }
  raise "Inspection changed installed state" unless BrewCooldown::Prototype::Inventory.capture == before
  puts JSON.pretty_generate(report)
  puts "PASS: native cask worker interruption at #{boundary} and read-only recovery"
  exit
end

if phase == "repair_forward"
  journal = BrewCooldown::Prototype::Journal.new(state)
  report = journal.report
  operation = report.fetch("operations").find { |entry| entry.fetch("kind") == "cask" }
  choice = operation.fetch("recovery").find { |entry| entry.fetch("purpose").start_with?("Repair forward") }
  raise "Cask forward repair is not explicit" unless choice.fetch("command").include?("--cask") &&
    choice.fetch("purpose").include?("outside the cooldown policy")
  output, status = Open3.capture2e(*Shellwords.split(choice.fetch("command")))
  puts output
  raise "Printed native forward repair failed" unless status.success?
  path = Cask::Caskroom.path/"codex/.metadata/INSTALL_RECEIPT.json"
  receipt = Cask::Tab.from_file_content(path.read, path)
  output, status = Open3.capture2((HOMEBREW_PREFIX/"bin/codex").to_s, "--version")
  raise "Repaired executable does not match the native receipt" unless status.success? && output.include?(receipt.version)
  raise "Native repair silently acknowledged the journal" unless journal.path.file?
  puts "PASS: operator-selected native cask forward repair restored a runnable installation"
  exit
end

if phase == "accept"
  require_relative "../../lib/brew_cooldown/recovery"
  before = BrewCooldown::Prototype::Inventory.capture
  recovery = BrewCooldown::Recovery.new(state_directory: state, log: ->(**event) { warn JSON.generate(event) })
  report = recovery.call
  raise "Cask journal was not recoverable" unless report.fetch(:status) == "needs_reconciliation" &&
    report.fetch(:operations).any? { |entry| entry.fetch("kind") == "cask" }
  accepted = recovery.call(accept_current: report.fetch(:accept_current).fetch("digest"))
  raise "Reviewed cask state was not accepted" unless accepted.fetch(:status) == "accepted_current"
  raise "Acceptance changed native packages" unless BrewCooldown::Prototype::Inventory.capture == before
  raise "Accepted cask journal retained" if (state/"active.json").exist?
  puts "PASS: explicit cask recovery acknowledgment without package mutation"
  exit
end

record = JSON.parse(File.read(File.join(__dir__, "cask_candidates.json"))).fetch("upgrade")
candidate = BrewCooldown::Prototype::CaskCandidate.new(record).prepare
previous = BrewCooldown::Prototype::CaskRetained.new("codex").cask
raise "Expected historical baseline" unless previous.version.to_s == "0.144.5"
retained = {}
pending = candidate.cask.depends_on.formula.dup
until pending.empty?
  name = pending.shift
  next if retained.key?(name)

  dependency = BrewCooldown::Prototype::Retained.new(Keg.new((HOMEBREW_PREFIX/"opt"/name).realpath))
  retained[name] = dependency
  pending.concat(dependency.runtime_dependencies.map { |entry| entry.fetch("full_name") })
end
map = BrewCooldown::Prototype::ExactMap.new(retained.values)
map.activate
BrewCooldown::Prototype::CaskMap.new(candidate, predecessor: previous).activate
operation = BrewCooldown::Prototype::CaskOperation.new(candidate, predecessor: previous)
execution = BrewCooldown::Prototype::Execution.new(map, state_directory: state, casks: [operation])
before = BrewCooldown::Prototype::Inventory.capture

case phase
when "drift"
  previous.pin
  begin
    changed = BrewCooldown::Prototype::Inventory.capture
    result = execution.apply(expected_inventory: before)
    raise "Native cask pin drift was not reported" unless result.fetch("status") == "drift" && result.fetch("changes").any?
    raise "Drift report omitted cask recovery" unless result.fetch("recovery").fetch("cask/codex").any?
    raise "Drift check changed installed state" unless BrewCooldown::Prototype::Inventory.capture == changed
  ensure
    previous.unpin
  end
  raise "Pin cleanup changed native state" unless BrewCooldown::Prototype::Inventory.capture == before
  puts "PASS: native cask pin drift and text-only repair choices"
when "failure"
  # A foreign file at the binary target exercises native conflict handling and
  # failed restoration. It must survive the failure rather than be overwritten.
  binary = HOMEBREW_PREFIX/"bin/codex"
  raise "Expected the native baseline binary link" unless binary.symlink?
  target = binary.readlink
  marker = "brew-cooldown disposable conflict fixture\n"
  binary.unlink
  binary.write(marker)
  begin
    result = execution.apply(expected_inventory: before)
    puts JSON.pretty_generate(result)
    raise "Native cask conflict was not reported" unless result.fetch("status") == "needs_reconciliation" &&
      result.fetch("operations").fetch(0).fetch("status") == "failed"
    raise "Conflicting file was overwritten" unless binary.file? && !binary.symlink? && binary.read == marker
    raise "Failed cask journal disappeared" unless execution.journal.path.file?
    raise "Failed cask recovery omitted commands" unless result.fetch("operations").fetch(0).fetch("recovery").all? { |entry| entry.fetch("command").include?("--cask") }
  ensure
    if binary.file? && !binary.symlink? && binary.read == marker
      binary.unlink
      binary.make_symlink(target)
    end
  end
  puts "PASS: native cask failure, retained journal and foreign-file preservation; inspect native restoration before repair"
when "interrupt_started", "interrupt_completed"
  boundary = phase.delete_prefix("interrupt_")
  execution.apply(expected_inventory: before) do |name, status|
    Process.kill("KILL", Process.pid) if name == "codex" && status == boundary
  end
  raise "Cask interruption boundary was not reached"
else
  raise "Unknown phase: #{phase}"
end
