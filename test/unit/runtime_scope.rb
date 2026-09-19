# frozen_string_literal: true

require_relative "../../lib/brew_cooldown/planner"
require_relative "../../lib/brew_cooldown/runtime_scope"

def package(name, kind: :formula, tap: "homebrew/core")
  BrewCooldown::PackageId.new(kind:, tap:, name:)
end

def needs(*packages)
  packages.map { |entry| BrewCooldown::RuntimeRequirement.new(package: entry) }
end

root = package("app", kind: :cask, tap: "homebrew/cask")
library = package("library")
leaf = package("leaf")
outside = package("outside-consumer")
other_tap = package("library", tap: "example/tools")
missing = package("missing")
graph = { root => needs(library, other_tap), library => needs(leaf), leaf => needs(library, missing),
          other_tap => [], outside => needs(leaf) }
result = BrewCooldown::RuntimeScope.expand(roots: [root], dependencies: graph)
# Following reverse consumers would silently broaden a Brewfile into unrelated
# application upgrades. Shared dependencies and cycles must not cause that.
raise "Runtime closure omitted a dependency or expanded reverse scope" unless result.keys.to_set ==
  [library, leaf, other_tap, missing].to_set
raise "Shared cycle lost its requesting consumers" unless result.fetch(library).to_set == [root, leaf].to_set
raise "Tap identity collapsed during traversal" unless result.fetch(other_tap) == [root]
raise "Missing installed edge was silently dropped" unless result.fetch(missing) == [leaf]

same_token = package("app")
combined = BrewCooldown::RuntimeScope.expand(roots: [root, same_token, root], dependencies: graph.merge(same_token => needs(leaf)))
raise "Formula/cask identity or shared-root provenance collapsed" unless combined.fetch(leaf).to_set == [library, same_token].to_set
raise "Empty scope discovered installed packages" unless BrewCooldown::RuntimeScope.expand(roots: [], dependencies: graph).empty?
puts "PASS: directed runtime scope, shared dependencies, cycles, missing evidence and canonical identities"
