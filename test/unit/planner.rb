# frozen_string_literal: true

require "digest"
require "time"
require_relative "../../lib/brew_cooldown/planner"
require_relative "../../lib/brew_cooldown/homebrew/build_order"
require_relative "../../lib/brew_cooldown/homebrew/compatibility"

def package(name)
  BrewCooldown::PackageId.new(kind: :formula, tap: "homebrew/core", name:)
end

def build(version)
  BrewCooldown::Build.new(version:, revision: 0, rebuild: 0, scheme: 0)
end

def requirement(name, version, cohort: nil)
  BrewCooldown::Requirement.new(package: package(name), build: build(version), compatibility_version: cohort)
end

def option(name, version, retained: false, dependencies: [], cohort: nil, status: :eligible,
           eligible_at: Time.iso8601("2026-09-01T00:00:00Z"))
  release = BrewCooldown::Release.new(package: package(name), build: build(version),
                        identity: Digest::SHA256.hexdigest([name, version, retained].join(":")),
                        verified: true, published_at: nil, publication_source: nil)
  decision = BrewCooldown::Decision.new(status:, reason: "test decision", eligible_at:, delay_kind: :patch,
                          age_source: :first_observation, fixed_advisories: [])
  BrewCooldown::Option.new(release:, decision:, dependencies:, compatibility_version: cohort, retained:)
end

def planner(budget: 100_000)
  BrewCooldown::Planner.new(compare_builds: BrewCooldown::HomebrewAdapter::BuildOrder, compatible: BrewCooldown::HomebrewAdapter::Compatibility,
              max_assignments: budget)
end

def resolve(options, roots:, budget: 100_000)
  planner(budget:).plan(domains: options.group_by { |entry| entry.release.package }, roots: roots.map { |name| package(name) })
end

def assert_version(result, name, version)
  actual = result.selected.fetch(package(name)).release.build.version
  raise "#{name}: expected #{version}, got #{actual}" unless actual == version
end

base_root = option("app", "1.0.0", retained: true, dependencies: [requirement("library", "1.0.0")])
base_library = option("library", "1.0.0", retained: true)
old_root = option("app", "1.0.1", dependencies: [requirement("library", "1.0.1")])
new_root = option("app", "1.0.2", dependencies: [requirement("library", "1.0.2")])
old_library = option("library", "1.0.1")
young_library = option("library", "1.0.2", status: :cooldown)

# A newer root cannot strand an older eligible dependency closure.
result = resolve([base_root, base_library, old_root, new_root, old_library, young_library], roots: ["app"]).fetch(0)
raise "Historical closure did not resolve" unless result.status == :resolved
assert_version(result, "app", "1.0.1")
assert_version(result, "library", "1.0.1")
raise "Rejected newest candidate lacks explanation" unless result.rejected_options.fetch(new_root.release.identity).include?("library")

# An unavailable optional dependency must not become a mandatory graph node
# after the solver falls back to a candidate that never needed it.
optional = option("app", "1.0.3", dependencies: [requirement("missing", "1.0.0")])
result = resolve([base_root, base_library, old_root, old_library, optional], roots: ["app"]).fetch(0)
assert_version(result, "app", "1.0.1")
raise "Unused absent dependency selected" if result.selected.key?(package("missing"))

# Missing upper ABI evidence protects a fixed consumer outside the root scope.
consumer = option("outside", "5.0.0", retained: true, dependencies: [requirement("library", "1.0.0")])
result = resolve([base_root, base_library, old_root, old_library, consumer], roots: ["app"]).fetch(0)
raise "Incompatible shared dependency changed" unless result.status == :unchanged
assert_version(result, "outside", "5.0.0")

# Matching native compatibility cohorts allow a dependency to advance while
# the consumer remains fixed; a minimum version alone is insufficient.
consumer = consumer.with(dependencies: [requirement("library", "1.0.0", cohort: 1)])
result = resolve([base_root, base_library, old_root, old_library.with(compatibility_version: 1), consumer], roots: ["app"]).fetch(0)
assert_version(result, "app", "1.0.1")
assert_version(result, "outside", "5.0.0")

# Native compatibility identifiers are explicit integers, not positive counts.
# Treating zero as absent would needlessly hold a compatible shared dependency.
zero_consumer = consumer.with(dependencies: [requirement("library", "1.0.0", cohort: 0)])
result = resolve([base_root, base_library, old_root, old_library.with(compatibility_version: 0), zero_consumer], roots: ["app"]).fetch(0)
assert_version(result, "app", "1.0.1")
assert_version(result, "outside", "5.0.0")

# Among compatible dependencies, preserve the installed choice before doing
# unnecessary work simply because a newer compatible release exists.
cohort_root = old_root.with(dependencies: [requirement("library", "1.0.1", cohort: 1)])
result = resolve([base_root, base_library.with(compatibility_version: 1), cohort_root,
                  old_library.with(compatibility_version: 1)], roots: ["app"]).fetch(0)
assert_version(result, "library", "1.0.0")

# An unrelated broken component must leave another root free to advance.
broken = option("broken", "2.0.0", dependencies: [requirement("absent", "2.0.0")])
independent = option("independent", "2.0.0")
results = resolve([broken, independent], roots: %w[broken independent])
raise "Independent components were coupled" unless results.map(&:status).sort == %i[no_compatible_solution resolved].sort
raise "Missing dependency was hidden" unless results.find { |entry| entry.status == :no_compatible_solution }.reason.include?("absent")

# Oldest eligible roots win shared-library tradeoffs. A security fix takes
# priority over that waiting order, without waiving the dependency's policy.
a_old = option("a", "1.0.0", retained: true, dependencies: [requirement("library", "1.0.0", cohort: 1)])
b_old = option("b", "1.0.0", retained: true, dependencies: [requirement("library", "1.0.0", cohort: 1)])
a_new = option("a", "1.0.1", dependencies: [requirement("library", "1.0.1")])
b_new = option("b", "1.0.1", dependencies: [requirement("library", "1.0.0")], eligible_at: Time.iso8601("2026-08-01T00:00:00Z"))
choices = [a_old, b_old, a_new, b_new, base_library.with(compatibility_version: 1), old_library.with(compatibility_version: 1)]
result = resolve(choices, roots: %w[a b]).fetch(0)
assert_version(result, "b", "1.0.1")
assert_version(result, "a", "1.0.0")
result = resolve(choices.map { |entry| entry == a_new ? entry.with(decision: entry.decision.with(status: :security_fix)) : entry }, roots: %w[a b]).fetch(0)
assert_version(result, "a", "1.0.1")
assert_version(result, "b", "1.0.0")
assert_version(result, "library", "1.0.1")

# A statically compatible cycle still lacks an executable dependency order.
cycle_a = option("cycle-a", "1.0.1", dependencies: [requirement("cycle-b", "1.0.1")])
cycle_b = option("cycle-b", "1.0.1", dependencies: [requirement("cycle-a", "1.0.1")])
result = resolve([cycle_a, cycle_b], roots: ["cycle-a"]).fetch(0)
raise "Unexecutable cycle accepted" unless result.status == :no_compatible_solution && result.reason.include?("circular")

result = resolve([old_root, old_library], roots: ["app"], budget: 1).fetch(0)
raise "Search limit misreported as incompatibility" unless result.status == :resolution_limit
raise "Budget exposed a partial assignment" unless result.selected.empty?

# Formula and cask tokens do not connect merely because their names match.
cask = independent.with(release: independent.release.with(package: package("independent").with(kind: :cask)))
domains = [independent, cask].group_by { |entry| entry.release.package }
results = planner.plan(domains:, roots: domains.keys)
raise "Formula/cask namespaces collided" unless results.length == 2 && results.all? { |entry| entry.status == :resolved }
puts "PASS: historical closure, shared consumers, backtracking, independent components and search limits"
