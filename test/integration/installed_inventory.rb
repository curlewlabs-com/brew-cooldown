# frozen_string_literal: true

require_relative "../../lib/brew_cooldown/homebrew/installed_inventory"
require_relative "../../lib/brew_cooldown/homebrew/scope"

before = BrewCooldown::Prototype::Inventory.capture
log = ->(**event) { warn JSON.generate(event) }
inventory = BrewCooldown::HomebrewAdapter::InstalledInventory.capture(log:)
after = BrewCooldown::Prototype::Inventory.capture
raise "Inventory read changed installed state" unless before == after
raise "Native inventory has errors; see diagnostics above" unless inventory.errors.empty?
raise "Expected installed core formulae" unless inventory.records.keys.any? { |package| package.tap == "homebrew/core" }

entries = BrewCooldown::HomebrewAdapter::Scope.read({ installed: true }, installed: inventory.records.keys)
raise "Installed scope lost inventory entries" unless entries.length == inventory.records.length
puts JSON.pretty_generate(inventory.records.values.map do |record|
  { package: record.installed.package.to_h, build: record.installed.build.to_h,
    pinned: record.installed.pinned, dependencies: record.dependencies.map { |edge| edge.package.to_h } }
end)
puts "PASS: native active inventory and installed scope without package changes"
