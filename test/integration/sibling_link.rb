# frozen_string_literal: true

require "open3"

abort "Run only in an expendable VM" unless ENV["HOMEBREW_COOLDOWN_DISPOSABLE"] == "1"
require_relative "../../lib/brew_cooldown/executor/execution"
BrewCooldown::Executor::Execution.check_homebrew!

def assert(condition, message)
  raise message unless condition
end

# lua is linked into the prefix and its tap names lua@5.4 as a sibling, so
# linking it walks the sibling list that an unlinked keg-only upgrade, such as
# the interpreter experiment's, never reaches.
phase = ARGV.fetch(0)
record = JSON.parse(File.read(File.join(__dir__, "sibling_candidates.json"))).fetch(phase)
candidate = BrewCooldown::Executor::Candidate.new(record).prepare
formula = candidate.formula
sibling_rack = HOMEBREW_CELLAR/"lua@5.4"
sibling_opt = HOMEBREW_PREFIX/"opt/lua@5.4"
if phase == "baseline"
  assert(formula.installed_kegs.empty? && !sibling_rack.exist?, "Baseline requires lua and lua@5.4 absent")
else
  assert(formula.linked?, "Upgrade requires the linked lua baseline")
  assert(sibling_opt.symlink? && !(HOMEBREW_LINKED_KEGS/"lua@5.4").exist?, "Upgrade requires an unlinked lua@5.4")
end
sibling_target = sibling_opt.readlink if sibling_opt.symlink?

map = BrewCooldown::Executor::ExactMap.new([candidate])
map.activate

# A sibling never installed is absent rather than an unplanned lookup, and an
# installed one is read from its own keg, never from today's recipe.
siblings = formula.link_overwrite_formulae
expected = phase == "baseline" ? [] : ["lua@5.4"]
assert(siblings.map(&:full_name) == expected, "Unexpected link siblings: #{siblings.map(&:full_name)}")
siblings.each do |sibling|
  assert(sibling.path.to_s.start_with?("#{sibling_rack}/"), "#{sibling.full_name} was not read from its keg")
end
# The allowance must end with the traversal, or any installed formula would
# become loadable outside the plan.
begin
  Formulary.factory("lua@5.4")
  raise "Sibling lookup was allowed outside link traversal"
rescue BrewCooldown::Executor::Refused => error
  raise unless error.message.include?("unplanned formula lookup")
end

inventory = BrewCooldown::Executor::Inventory.capture
execution = BrewCooldown::Executor::Execution.new(map, state_directory: ENV.fetch("HOMEBREW_COOLDOWN_TEST_STATE"))
result = execution.apply(expected_inventory: inventory)
puts JSON.pretty_generate(result)
assert(result.fetch("status") == "completed", "Sibling-family operation failed")

keg = HOMEBREW_CELLAR/"lua"/record.fetch("version")
assert((HOMEBREW_LINKED_KEGS/"lua").realpath == keg, "lua is not linked to the selected keg")
output, status = Open3.capture2e((HOMEBREW_PREFIX/"bin/lua").to_s, "-v")
assert(status.success? && output.include?("Lua #{record.fetch('version')}"), "Linked lua failed: #{output}")
if phase == "upgrade"
  assert(sibling_opt.readlink == sibling_target, "lua@5.4 opt link changed")
  assert(!(HOMEBREW_LINKED_KEGS/"lua@5.4").exist?, "lua@5.4 was linked")
end
puts "PASS #{phase}: linked lua with its siblings answered from installed kegs only"
