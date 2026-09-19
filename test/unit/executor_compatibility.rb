# frozen_string_literal: true

require_relative "../../prototype/compatibility"

# Retained dependencies follow native package-version requirements. New
# artifacts still need exact recorded builds or explicit compatibility cohorts.
formula = Data.define(:name, :pkg_version).new(name: "library", pkg_version: PkgVersion.parse("1.0.0"))
target = Data.define(:formula, :rebuild, :compatibility_version, :install?).new(formula:, rebuild: nil, compatibility_version: nil, install?: true)
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
BrewCooldown::Prototype::Compatibility.validate!(requirement, target.with(install?: false))
begin
  BrewCooldown::Prototype::Compatibility.validate!(requirement.merge("pkg_version" => "1.0.1"), target.with(install?: false))
rescue BrewCooldown::Prototype::Refused
  mismatched_version_rejected = true
end
raise "A different retained package version was accepted without compatibility evidence" unless mismatched_version_rejected
BrewCooldown::Prototype::Compatibility.validate!(requirement.merge("compatibility_version" => 0),
                                               target.with(compatibility_version: 0))
puts "PASS: native-only rebuild evidence and explicit compatibility cohorts"
