# frozen_string_literal: true

require_relative "../../lib/brew_cooldown/forked_component"
require_relative "../../prototype/exact_map"

log = ->(**_event) {}
raise "Parent already has an execution map" if BrewCooldown::Prototype.active_map
result = BrewCooldown::ForkedComponent.call(log:) do
  # Native guards must not contaminate the next component or parent discovery.
  BrewCooldown::Prototype.active_map = :child_only
  { "status" => "completed", "operations" => ["selected"] }
end
raise "Child result lost" unless result == { "status" => "completed", "operations" => ["selected"] }
raise "Native map leaked into parent" if BrewCooldown::Prototype.active_map
result = BrewCooldown::ForkedComponent.call(log:) { raise "component failure" }
raise "Worker exception hidden" unless result["status"] == "error" && result["error"].include?("component failure")
result = BrewCooldown::ForkedComponent.call(log:) { Process.kill("KILL", Process.pid) }
raise "Worker death looked successful" unless result["status"] == "interrupted"
puts "PASS: component process isolation, errors and unconfirmed worker death"
