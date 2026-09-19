# frozen_string_literal: true

require_relative "../../prototype/compatibility"

# The execution adapter must use the same evidence standard as the planner:
# unknown build metadata is not zero, and two unknowns do not match exactly.
formula = Data.define(:name, :pkg_version).new(name: "library", pkg_version: PkgVersion.parse("1.0.0"))
target = Data.define(:formula, :rebuild, :compatibility_version).new(formula:, rebuild: nil, compatibility_version: nil)
requirement = { "pkg_version" => "1.0.0" }
[[requirement, target], [requirement, target.with(rebuild: 0)],
 [requirement.merge("bottle_rebuild" => 0), target]].each do |dependency, selected|
  begin
    BrewCooldown::Prototype::Compatibility.validate!(dependency, selected)
  rescue BrewCooldown::Prototype::Refused
    next
  end
  raise "Unknown rebuild accepted as exact compatibility evidence"
end
BrewCooldown::Prototype::Compatibility.validate!(requirement.merge("bottle_rebuild" => 0), target.with(rebuild: 0))
BrewCooldown::Prototype::Compatibility.validate!(requirement.merge("compatibility_version" => 0),
                                               target.with(compatibility_version: 0))
puts "PASS: native-only rebuild evidence and explicit compatibility cohorts"
