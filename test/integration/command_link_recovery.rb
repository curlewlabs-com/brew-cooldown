# frozen_string_literal: true

require "open3"
require "stringio"

abort "Run only in an expendable VM" unless ENV["HOMEBREW_COOLDOWN_DISPOSABLE"] == "1"
require_relative "../../lib/brew_cooldown/executor/execution"
require_relative "../../lib/brew_cooldown/recovery"
require_relative "../../lib/brew_cooldown/report"
BrewCooldown::Executor::Execution.check_homebrew!

def assert(condition, message)
  raise message unless condition
end

directory = ENV.fetch("HOMEBREW_COOLDOWN_TEST_STATE")
keg = Keg.new((HOMEBREW_PREFIX/"opt/coreutils").realpath)
journal = BrewCooldown::Executor::Journal.new(directory)
if ARGV.first == "interrupt"
  # Kill inside real native unlink, after bin was removed but before its
  # linked-keg record is cleared. Receipts alone cannot detect this damage.
  module InterruptInfo
    def uninstall_info(*)
      Process.kill("KILL", Process.pid)
    end
  end
  Utils::Path.singleton_class.prepend(InterruptInfo)
  journal.with_lock do
    journal.start([{ "kind" => "formula", "name" => "coreutils", "version" => "9.12_1", "previous_keg" => keg.to_s,
                     "status" => "pending", "keg_only" => false }], BrewCooldown::Executor::Inventory.capture)
    journal.record("coreutils", "started")
    keg.unlink
  end
  raise "Unlink interruption was not reached"
end

before = BrewCooldown::Executor::Inventory.capture
output, status = Open3.capture2e(HOMEBREW_BREW_FILE.to_s, "ruby", "--", __FILE__, "interrupt")
puts output
assert(status.signaled? && status.termsig == Signal.list.fetch("KILL"), "Child was not killed during unlink")
assert(!((HOMEBREW_PREFIX/"bin/gtimeout").symlink?), "Unlink did not remove gtimeout")
assert(keg.linked? && keg.optlinked?, "Fixture did not retain misleading linked/opt records")
assert((keg/"INSTALL_RECEIPT.json").file?, "Unlink removed the retained keg")

log = ->(**entry) { warn JSON.generate(entry) }
recovery = BrewCooldown::Recovery.new(state_directory: directory, log:)
report = recovery.call
puts JSON.pretty_generate(report)
missing = report.fetch(:drift).find { |change| change.fetch("path") == (HOMEBREW_PREFIX/"bin/gtimeout").to_s }
assert(missing && missing.fetch("expected") && missing.fetch("observed").nil?, "Recovery missed removed command link")
human = StringIO.new
BrewCooldown::Report.print_recovery(report, human)
assert(human.string.include?((HOMEBREW_PREFIX/"bin/gtimeout").to_s), "Human recovery omitted the missing command")
digest = report.fetch(:accept_current).fetch("digest")

begin
  BrewCooldown::Executor::Inventory.verify_commands!(keg)
  raise "Receipt and linked-keg record concealed missing commands"
rescue BrewCooldown::Executor::Refused => error
  assert(error.message.include?("linked command missing or redirected"), "Wrong command verification error")
end

# Legacy journals remain readable, but their absent baseline must not be
# confused with evidence that commands survived the failed operation.
original = journal.path.read
legacy = JSON.parse(original)
legacy["schema"] = 1
legacy["inventory"].reject! { |path, _| BrewCooldown::Executor::Inventory.command_link?(path) }
begin
  journal.path.write(JSON.generate(legacy))
  old_report = recovery.call
  assert(!old_report.fetch(:unverified).empty?, "Legacy command-link coverage was not disclosed")
  assert(old_report.fetch(:drift).empty?, "Legacy journal invented a command-link baseline")
  human = StringIO.new
  BrewCooldown::Report.print_recovery(old_report, human)
  assert(human.string.include?("pre-upgrade command links were not recorded"), "Human recovery concealed legacy coverage")
ensure
  journal.path.write(original)
end

choice = report.fetch(:operations).first.fetch("recovery").find do |entry|
  entry.fetch("purpose").start_with?("Restore retained keg links")
end
assert(choice, "Recovery omitted retained-keg restoration")
output, status = Open3.capture2e("/bin/sh", "-c", choice.fetch("command"))
puts output
assert(status.success?, "Printed retained-keg recovery failed")
BrewCooldown::Executor::Inventory.verify_commands!(keg)
assert(BrewCooldown::Executor::Inventory.capture == before, "Recovery did not restore the original inventory")
rejected = recovery.call(accept_current: digest)
assert(rejected.fetch(:status) == "error" && journal.path.exist?, "Restored command links accepted stale acknowledgment")
fresh = recovery.call
assert(fresh.fetch(:drift).empty?, "Restored links still differ from baseline")
assert(fresh.fetch(:accept_current).fetch("digest") != digest, "Acknowledgment omitted command links")
accepted = recovery.call(accept_current: fresh.fetch(:accept_current).fetch("digest"))
assert(accepted.fetch(:status) == "accepted_current" && !journal.path.exist?, "Fresh acknowledgment failed")
output, status = Open3.capture2e((HOMEBREW_PREFIX/"bin/gtimeout").to_s, "--version")
assert(status.success? && output.include?("GNU coreutils) 9.12"), "Restored command failed")
puts "PASS: interrupted unlink, missing commands, legacy coverage, retained-keg restoration and stale acknowledgment"
