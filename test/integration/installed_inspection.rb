# frozen_string_literal: true

require "open3"

abort "Run only in an expendable VM" unless ENV["HOMEBREW_COOLDOWN_DISPOSABLE"] == "1"
require_relative "../../lib/brew_cooldown/executor/execution"
BrewCooldown::Executor::Execution.check_homebrew!

def assert(condition, message)
  raise message unless condition
end

def refuses(description)
  before = BrewCooldown::Executor::Inventory.capture
  begin
    yield
  rescue BrewCooldown::Executor::Refused => error
    assert(BrewCooldown::Executor::Inventory.capture == before, "#{description} changed packages")
    puts "PASS refused #{description}: #{error.message}"
    return
  end
  raise "Accepted #{description}"
end

phase, helper = ARGV
assert(%w[baseline upgrade].include?(phase) && %w[absent installed].include?(helper), "Unknown phase/helper")
assert(!File.executable?("/usr/bin/install-info"), "Fixture needs Homebrew's optional helper path")
assert((HOMEBREW_CELLAR/"texinfo").directory? == (helper == "installed"), "Unexpected helper state")

record = JSON.parse(File.read(File.join(__dir__, "info_candidates.json"))).fetch(phase)
candidate = BrewCooldown::Executor::Candidate.new(record).prepare
dependencies = candidate.runtime_dependencies.map do |entry|
  name = entry.fetch("full_name").delete_prefix("homebrew/core/")
  BrewCooldown::Executor::Retained.new(Keg.new((HOMEBREW_PREFIX/"opt"/name).realpath))
end
assert(phase != "baseline" || candidate.formula.installed_kegs.empty?, "Baseline requires Coreutils absent")
assert(phase != "upgrade" || Keg.new(candidate.formula.opt_prefix.realpath).version.to_s == "9.12", "Missing baseline")
map = BrewCooldown::Executor::ExactMap.new([*dependencies, candidate])
map.activate

# Even an installed helper cannot become a selected package merely because
# native bookkeeping inspected it. gh is present in both fixture variants.
refuses("helper candidate lookup") { Formulary.factory("texinfo") }
inspected = BrewCooldown::Executor::InstalledState.formula("gh")
refuses("installer for an inspected formula") { FormulaInstaller.new(inspected) }
unplanned = Keg.new(inspected.opt_prefix.realpath)
%i[unlink link optlink uninstall].each do |operation|
  refuses("unplanned keg #{operation}") { unplanned.public_send(operation) }
end
BrewCooldown::Executor.executing_name = "coreutils"
begin
  dependencies.each do |retained|
    refuses("unlink retained dependency during Coreutils operation") { retained.keg.unlink }
  end
ensure
  BrewCooldown::Executor.executing_name = nil
end

selected = Utils::Path.send(:install_info_executable)
expected = helper == "installed" ? (HOMEBREW_PREFIX/"opt/texinfo/bin/install-info").to_s : nil
assert(selected == expected, "Wrong optional helper: #{selected.inspect}")
if phase == "upgrade" && helper == "installed"
  # An incomplete helper installation must fail before removing Coreutils'
  # existing commands, not when unlink eventually reaches share/info.
  opt = HOMEBREW_PREFIX/"opt/texinfo"
  target = opt.readlink
  opt.unlink
  begin
    before = BrewCooldown::Executor::Inventory.capture
    probe = BrewCooldown::Executor::Execution.new(map, state_directory: ENV.fetch("HOMEBREW_COOLDOWN_TEST_STATE"))
    failure = probe.apply(expected_inventory: before)
    assert(failure.fetch("status") == "error" && failure.fetch("error").include?("installed helper has no active keg"),
           "Broken helper was not refused in preflight: #{failure}")
    assert(BrewCooldown::Executor::Inventory.capture == before, "Helper preflight changed command links or packages")
    assert((HOMEBREW_PREFIX/"bin/gtimeout").executable?, "Preflight removed an existing command")
  ensure
    opt.make_symlink(target)
  end
end
inventory = BrewCooldown::Executor::Inventory.capture
execution = BrewCooldown::Executor::Execution.new(map, state_directory: ENV.fetch("HOMEBREW_COOLDOWN_TEST_STATE"))
result = execution.apply(expected_inventory: inventory)
puts JSON.pretty_generate(result)
assert(result.fetch("status") == "completed", "Coreutils #{phase} failed with helper #{helper}")

%w[gtimeout timeout].each do |name|
  path = HOMEBREW_PREFIX/"bin"/name
  assert(path.symlink? && path.realpath == (candidate.formula.prefix/"bin"/name).realpath, "Wrong command link #{path}")
  output, status = Open3.capture2e(path.to_s, "--version")
  assert(status.success? && output.include?("GNU coreutils) 9.12"), "Linked command failed: #{output}")
end
assert((HOMEBREW_CELLAR/"texinfo").directory? == (helper == "installed"), "Changed optional helper installation")
puts "PASS #{phase}: Coreutils with helper #{helper}, exact authority and working prefix commands"
