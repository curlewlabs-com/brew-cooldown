# frozen_string_literal: true

require "open3"

abort "Run only in an expendable VM" unless ENV["HOMEBREW_COOLDOWN_DISPOSABLE"] == "1"
require_relative "../../lib/brew_cooldown/executor/execution"
BrewCooldown::Executor::Execution.check_homebrew!

def assert(condition, message)
  raise message unless condition
end

# opentofu's recipe declares conflicts_with "tenv", and native conflict checking
# loads tenv's recipe before pouring whether or not tenv is installed. That
# lookup is outside the plan, so it stopped every opentofu upgrade until the
# installer answered conflicts from the prefix.
phase = ARGV.fetch(0)
record = JSON.parse(File.read(File.join(__dir__, "conflict_candidates.json")))
               .fetch(phase == "baseline" ? "baseline" : "upgrade")
candidate = BrewCooldown::Executor::Candidate.new(record).prepare
formula = candidate.formula
assert(formula.conflicts.map(&:name).include?("tenv"), "Fixture recipe no longer conflicts with tenv")
tenv_rack = HOMEBREW_CELLAR/"tenv"
tenv_linked = HOMEBREW_LINKED_KEGS/"tenv"
case phase
when "baseline"
  assert(formula.installed_kegs.empty? && !tenv_rack.exist?, "Baseline requires opentofu and tenv absent")
when "linked"
  assert(!formula.linked? && tenv_linked.exist?, "Linked phase requires an unlinked opentofu beside a linked tenv")
else
  assert(formula.linked? && tenv_rack.exist? && !tenv_linked.exist?,
         "Upgrade requires the linked opentofu baseline beside an unlinked tenv")
end

map = BrewCooldown::Executor::ExactMap.new([candidate])
map.activate

# Answering from the prefix must not also make tenv loadable.
begin
  Formulary.factory("tenv")
  raise "Conflict lookup was allowed outside the plan"
rescue BrewCooldown::Executor::Refused => error
  raise unless error.message.include?("unplanned formula lookup")
end

if phase == "linked"
  # A linked conflict still stops the installation before anything is poured.
  begin
    FormulaInstaller.new(formula, link_keg: true).check_conflicts
    raise "Linked tenv was not reported as a conflict"
  rescue FormulaConflictError => error
    assert(error.conflicts.map(&:name) == ["tenv"], "Unexpected conflicts: #{error.conflicts.map(&:name)}")
  end
  puts "PASS linked: refused #{formula.full_name} beside a linked tenv"
  exit
end

inventory = BrewCooldown::Executor::Inventory.capture
execution = BrewCooldown::Executor::Execution.new(map, state_directory: ENV.fetch("HOMEBREW_COOLDOWN_TEST_STATE"))
result = execution.apply(expected_inventory: inventory)
puts JSON.pretty_generate(result)
assert(result.fetch("status") == "completed", "Conflict-declaring operation failed")

keg = HOMEBREW_CELLAR/"opentofu"/record.fetch("version")
assert((HOMEBREW_LINKED_KEGS/"opentofu").realpath == keg, "opentofu is not linked to the selected keg")
output, status = Open3.capture2e((HOMEBREW_PREFIX/"bin/tofu").to_s, "version")
assert(status.success? && output.include?("OpenTofu v#{record.fetch('version')}"), "Linked tofu failed: #{output}")
assert(phase == "baseline" || !tenv_linked.exist?, "tenv was linked")
puts "PASS #{phase}: installed #{formula.full_name} with its conflicts answered from the prefix"
