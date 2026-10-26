# frozen_string_literal: true

require_relative "../../lib/brew_cooldown/executor/formula_operation"
require_relative "../../lib/brew_cooldown/upgrade"

# Upgrading python@3.14 from 3.14.7 to 3.14.8 after Homebrew moved the python,
# python3 and python@3 aliases to python@3.15 changed these links. The upgrade
# was refused as an unplanned inventory change although every link had pointed
# at the replaced keg.
formula = Data.define(:name, :rack, :aliases, :oldnames)
                .new(name: "python@3.14", rack: HOMEBREW_CELLAR/"python@3.14", aliases: [], oldnames: [])
operation = BrewCooldown::Executor::FormulaOperation.new(Data.define(:formula).new(formula:), map: nil)
opt = HOMEBREW_PREFIX/"opt"
change = ->(path, expected, observed) { { "path" => path.to_s, "expected" => expected, "observed" => observed } }

owned = [
  change.call(opt/"python", "../Cellar/python@3.14/3.14.7", nil),
  change.call(opt/"python3", "../Cellar/python@3.14/3.14.7", nil),
  change.call(opt/"python@3", "../Cellar/python@3.14/3.14.7", "../Cellar/python@3.14/3.14.8"),
  change.call(HOMEBREW_LINKED_KEGS/"python", "../../../Cellar/python@3.14/3.14.7", nil),
  change.call(opt/"python@3.14", "../Cellar/python@3.14/3.14.7", "../Cellar/python@3.14/3.14.8"),
  change.call(HOMEBREW_CELLAR/"python@3.14/3.14.8/INSTALL_RECEIPT.json", nil, "0" * 64)
]
owned.concat([
  change.call(HOMEBREW_PREFIX/"bin/python3.14", "../Cellar/python@3.14/3.14.7/bin/python3.14", nil),
  change.call(HOMEBREW_PREFIX/"bin/python3.14", nil, "../Cellar/python@3.14/3.14.8/bin/python3.14"),
  change.call(HOMEBREW_PREFIX/"sbin/python-helper", "../Cellar/python@3.14/3.14.7/sbin/python-helper",
              "../Cellar/python@3.14/3.14.8/sbin/python-helper")
])
owned.each { |entry| raise "Own link change refused: #{entry}" unless operation.owns_change?(entry) }

# Each of these changes a link this keg did not hold before the upgrade, or
# hands one to another formula, which the operation cannot have meant to do.
foreign = [
  change.call(opt/"python3", "../Cellar/python@3.15/3.15.0", nil),
  change.call(opt/"python3", "../Cellar/python@3.14/3.14.7", "../Cellar/python@3.15/3.15.0"),
  change.call(opt/"python3", nil, "../Cellar/python@3.14/3.14.8"),
  change.call(opt/"python3", "../Cellar/python@3.14t/3.14.7", nil),
  change.call(HOMEBREW_PINNED_KEGS/"python@3.14", "../../../Cellar/python@3.14/3.14.7", nil),
  change.call(HOMEBREW_CELLAR/"python@3.15/3.15.0/INSTALL_RECEIPT.json", "0" * 64, "1" * 64)
]
foreign.concat([
  change.call(HOMEBREW_PREFIX/"bin/python3", "../Cellar/python@3.15/3.15.0/bin/python3", nil),
  change.call(HOMEBREW_PREFIX/"bin/python3", "../Cellar/python@3.14/3.14.7/bin/python3", "/tmp/python3"),
  change.call(HOMEBREW_PREFIX/"sbin/python-helper", nil, "../Cellar/python@3.14t/3.14.7/sbin/python-helper")
])
foreign.each { |entry| raise "Foreign change accepted: #{entry}" if operation.owns_change?(entry) }

# The upgrade rechecks the inventory after each component before starting the
# next. When it kept its own copy of the rule, upgrading python@3.14 3.14.8 to
# 3.14.8_1 completed and then failed the run on the opt/python@3 link the
# executor had just accepted.
package = BrewCooldown::PackageId.new(kind: :formula, tap: "homebrew/core", name: "python@3.14")
release = Data.define(:package, :identity).new(package:, identity: "python@3.14 3.14.8")
option = Data.define(:release, :retained).new(release:, retained: false)
resolution = Data.define(:selected).new(selected: { package => option })
prepared = { release.identity => Data.define(:formula).new(formula:) }
upgrade = BrewCooldown::Upgrade.allocate
owned.each do |entry|
  raise "Upgrade refused an owned change: #{entry}" unless upgrade.send(:owned_change?, entry, resolution, prepared)
end
foreign.each do |entry|
  raise "Upgrade accepted a foreign change: #{entry}" if upgrade.send(:owned_change?, entry, resolution, prepared)
end
puts "PASS: links that pointed into the replaced keg's rack, and no others"
