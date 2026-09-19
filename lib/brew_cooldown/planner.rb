# frozen_string_literal: true

require "set"
require_relative "policy"

module BrewCooldown
  Requirement = Data.define(:package, :build, :compatibility_version) do
    def description = "compatible with #{build.version}"
  end
  RuntimeRequirement = Data.define(:package) do
    def description = "installed and active"
  end
  Option = Data.define(:release, :decision, :dependencies, :compatibility_version, :retained)
  Resolution = Data.define(:roots, :status, :selected, :attempts, :reason, :rejected_options)

  # Domains come from scoped discovery, including fixed installed consumers.
  # Only selected options activate previously absent dependencies.
  class Planner
    class SearchLimit < StandardError; end

    def initialize(compare_builds:, compatible:, max_assignments: 100_000)
      raise ArgumentError, "assignment budget must be a positive integer" unless
        max_assignments.is_a?(Integer) && max_assignments.positive?

      @compare_builds = compare_builds
      @compatible = compatible
      @max_assignments = max_assignments
    end

    def plan(domains:, roots:)
      eligible = domains.transform_values { |options| options.select { |option| option.retained || option.decision.eligible? } }
      components(eligible, roots).map do |component|
        component_roots = roots.select { |root| component.include?(root) }
        resolve(eligible.slice(*component), component_roots)
      end
    end

    private

    def key(package)
      [package.kind.to_s, package.tap, package.name]
    end

    def components(domains, roots)
      edges = Hash.new { |hash, package| hash[package] = Set.new }
      domains.each do |package, options|
        edges[package]
        options.each do |option|
          option.dependencies.each do |requirement|
            edges[package] << requirement.package
            edges[requirement.package] << package
          end
        end
      end
      visited = Set.new
      roots.sort_by { |root| key(root) }.filter_map do |root|
        next if visited.include?(root)

        component = Set.new
        pending = [root]
        until pending.empty?
          package = pending.pop
          next unless component.add?(package)

          pending.concat(edges[package].to_a)
        end
        visited.merge(component)
        component.to_a
      end
    end

    def resolve(domains, roots)
      @attempts = 0
      @rejected = Set.new
      @last_conflict = nil
      @conflicts = {}
      @domains = domains
      @priority = roots.sort_by do |root|
        upgrades = domains.fetch(root, []).reject(&:retained)
        security = upgrades.any? { |option| option.decision.status == :security_fix }
        oldest = upgrades.filter_map { |option| option.decision.eligible_at }.min
        [security ? 0 : 1, oldest ? oldest.to_r : Float::INFINITY, key(root)]
      end
      @domains = domains.to_h do |package, options|
        ordered = options.sort do |left, right|
          if !roots.include?(package) && left.retained != right.retained
            left.retained ? -1 : 1
          else
            comparison = @compare_builds.call(right.release.build, left.release.build)
            if comparison.zero? && left.release.published_at && right.release.published_at
              comparison = right.release.published_at <=> left.release.published_at
            end
            comparison.zero? ? left.release.identity <=> right.release.identity : comparison
          end
        end
        [package, ordered]
      end
      # Existing consumers remain constraints even if a different candidate
      # stops using their shared dependency. Absent optional dependencies do not.
      required = roots.to_set | domains.select { |_package, options| options.any?(&:retained) }.keys.to_set
      selected = search({}, required)
      unless selected
        return Resolution.new(roots:, status: :no_compatible_solution, selected: {}.freeze,
                              attempts: @attempts, reason: @last_conflict || "No compatible assignment",
                              rejected_options: @conflicts.freeze)
      end

      status = selected.values.all?(&:retained) ? :unchanged : :resolved
      Resolution.new(roots:, status:, selected: selected.freeze, attempts: @attempts, reason: nil,
                     rejected_options: @conflicts.freeze)
    rescue SearchLimit
      Resolution.new(roots:, status: :resolution_limit, selected: {}.freeze, attempts: @attempts,
                     reason: "Assignment budget exhausted before resolving this component",
                     rejected_options: @conflicts.freeze)
    end

    def search(selected, required)
      signature = selected.sort_by { |package, _option| key(package) }
                          .map { |package, option| [package, option.release.identity] }
      return if @rejected.include?(signature)
      if required.all? { |package| selected.key?(package) }
        return selected unless installation_cycle?(selected)

        @last_conflict = "Selected upgrades have a circular installation dependency"
        @rejected << signature
        return
      end

      unassigned = required.reject { |package| selected.key?(package) }
      package = @priority.find { |root| unassigned.include?(root) } || unassigned.min_by { |entry| key(entry) }
      options = @domains.fetch(package, [])
      @last_conflict = "No eligible option for #{key(package).join('/')}" if options.empty?
      options.each do |option|
        raise SearchLimit if @attempts >= @max_assignments

        @attempts += 1
        assignment = selected.merge(package => option)
        if consistent?(assignment)
          needed = required | option.dependencies.map(&:package).to_set
          result = search(assignment, needed)
          return result if result
        end
        @conflicts[option.release.identity] = @last_conflict if @priority.include?(package)
      end
      @rejected << signature
      nil
    end

    def consistent?(selected)
      selected.all? do |package, option|
        option.dependencies.all? do |requirement|
          targets = selected.key?(requirement.package) ? [selected.fetch(requirement.package)] : @domains.fetch(requirement.package, [])
          compatible = targets.any? do |target|
            (option.retained && target.retained) || @compatible.call(requirement, target)
          end
          unless compatible
            @last_conflict = "#{key(package).join('/')} #{option.release.build.version} requires " \
                             "#{key(requirement.package).join('/')} #{requirement.description}"
          end
          compatible
        end
      end
    end

    def installation_cycle?(selected)
      visiting = Set.new
      visited = Set.new
      visit = lambda do |package|
        return false if selected.fetch(package).retained || visited.include?(package)
        return true if visiting.include?(package)

        visiting << package
        return true if selected.fetch(package).dependencies.any? { |edge| visit.call(edge.package) }

        visiting.delete(package)
        visited << package
        false
      end
      selected.keys.any? { |package| visit.call(package) }
    end
  end
end
