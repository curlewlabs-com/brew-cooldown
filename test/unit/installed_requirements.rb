# frozen_string_literal: true

require_relative "../../lib/brew_cooldown/homebrew/installed_inventory"

native = { "full_name" => "python@3.14", "pkg_version" => "3.14.0_1", "bottle_rebuild" => 2,
           "compatibility_version" => 0 }
requirement = BrewCooldown::HomebrewAdapter::InstalledInventory.requirements([native]).first
raise "Revision lost from receipt" unless requirement.build.version == "3.14.0" && requirement.build.revision == 1
raise "Explicit compatibility lost" unless requirement.compatibility_version == 0
raise "Versioned package identity lost" unless requirement.package.name == "python@3.14" && requirement.package.tap == "homebrew/core"
unknown = BrewCooldown::HomebrewAdapter::InstalledInventory.requirements([native.reject { |key, _| key == "bottle_rebuild" }]).first
raise "Missing rebuild became zero" unless unknown.build.rebuild.nil?
tapped = BrewCooldown::HomebrewAdapter::InstalledInventory.requirements([native.merge("full_name" => "example/tap/python@3.14")]).first
raise "Third-party tap became core" unless tapped.package.tap == "example/tap"

[nil, [nil], [native.merge("bottle_rebuild" => "2")], [native.merge("compatibility_version" => false)]].each do |rows|
  begin
    BrewCooldown::HomebrewAdapter::InstalledInventory.requirements(rows)
    raise "Invalid receipt accepted"
  rescue ArgumentError
    # A malformed receipt cannot become an empty dependency list.
  end
end
puts "PASS: native dependency identities, formula revisions, explicit cohorts and unknown rebuilds"

# Cask receipts observe local dependencies, not the vendor's binary build.
# Preserve package identity without inventing an exact bottle ABI constraint.
presence = BrewCooldown::HomebrewAdapter::InstalledInventory.cask_requirements({ "formula" => [native],
  "cask" => [{ "full_name" => "homebrew/cask/codex", "version" => "0.144.6" }] })
raise "Cask dependency became a bottle ABI requirement" unless presence.all? { |entry| entry.is_a?(BrewCooldown::RuntimeRequirement) }
raise "Cask dependency kind was lost" unless presence.last.package.kind == :cask && presence.last.package.tap == "homebrew/cask"
[nil, { "formula" => nil }, { "formula" => [{ "full_name" => "../escape" }] }, { "cask" => [nil] }].each do |runtime|
  begin
    BrewCooldown::HomebrewAdapter::InstalledInventory.cask_requirements(runtime)
  rescue ArgumentError
    next
  end
  raise "Invalid cask dependency evidence accepted"
end
