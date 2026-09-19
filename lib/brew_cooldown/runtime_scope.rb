# frozen_string_literal: true

require "set"

module BrewCooldown
  # Installed receipt edges define proactive upgrade scope. Reverse consumers
  # belong to compatibility planning, so this traversal follows outgoing edges.
  module RuntimeScope
    def self.expand(roots:, dependencies:)
      required_by = Hash.new { |rows, package| rows[package] = Set.new }
      visited = Set.new
      pending = roots.dup
      until pending.empty?
        package = pending.shift
        next unless visited.add?(package)

        dependencies.fetch(package, []).each do |requirement|
          required_by[requirement.package] << package
          pending << requirement.package
        end
      end
      required_by.transform_values(&:to_a)
    end
  end
end
