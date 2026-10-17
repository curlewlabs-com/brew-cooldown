# frozen_string_literal: true

require "open3"

abort "Run only in an expendable VM" unless ENV["HOMEBREW_COOLDOWN_DISPOSABLE"] == "1"
require_relative "../../lib/brew_cooldown/executor/execution"
BrewCooldown::Executor::Execution.check_homebrew!

def assert(condition, message)
  raise message unless condition
end

# A receipt records the aliases the tap gave a formula when it was installed,
# and the tap can later give them to another formula: python and python3 moved
# to python@3.15 while python@3.14 3.14.7 was installed. A fresh VM installs
# only under today's aliases, so this restores that shape on the sibling-link
# baseline. lua-moved stands for opt/python, a recorded alias that unlinking
# the old keg removes. lua-renamed stands for opt/python@3, a link into the
# rack that no current name covers, which linking the new keg moves.
records = JSON.parse(File.read(File.join(__dir__, "sibling_candidates.json")))
baseline = HOMEBREW_CELLAR/"lua"/records.fetch("baseline").fetch("version")
assert((HOMEBREW_LINKED_KEGS/"lua").symlink? && (HOMEBREW_LINKED_KEGS/"lua").realpath == baseline,
       "Requires the linked lua baseline from sibling_link.rb")
moved = HOMEBREW_PREFIX/"opt/lua-moved"
renamed = HOMEBREW_PREFIX/"opt/lua-renamed"
assert(!moved.symlink? && !renamed.symlink?, "Alias fixture links already exist")
tab = Tab.for_keg(Keg.new(baseline))
tab.aliases = ["lua-moved"]
tab.write
[moved, renamed].each { |link| link.make_relative_symlink(baseline) }

record = records.fetch("upgrade")
candidate = BrewCooldown::Executor::Candidate.new(record).prepare
map = BrewCooldown::Executor::ExactMap.new([candidate])
map.activate
inventory = BrewCooldown::Executor::Inventory.capture
execution = BrewCooldown::Executor::Execution.new(map, state_directory: ENV.fetch("HOMEBREW_COOLDOWN_TEST_STATE"))
result = execution.apply(expected_inventory: inventory)
puts JSON.pretty_generate(result)
assert(result.fetch("status") == "completed", "Upgrade across a moved alias failed")

keg = HOMEBREW_CELLAR/"lua"/record.fetch("version")
assert(!moved.symlink?, "The replaced keg's recorded alias link survived")
assert(renamed.symlink? && renamed.realpath == keg, "The link into the rack was not moved to the new keg")
assert((HOMEBREW_LINKED_KEGS/"lua").realpath == keg, "lua is not linked to the selected keg")
output, status = Open3.capture2e((HOMEBREW_PREFIX/"bin/lua").to_s, "-v")
assert(status.success? && output.include?("Lua #{record.fetch('version')}"), "Linked lua failed: #{output}")
puts "PASS: the upgrade removed and moved only links that pointed into its own rack"
