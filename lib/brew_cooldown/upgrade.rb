# frozen_string_literal: true

require_relative "planning"
require_relative "journals"
require_relative "forked_component"
require_relative "homebrew/revalidation"
require_relative "../../prototype/execution"

module BrewCooldown
  class Upgrade
    def initialize(config:, scope:, state_directory:, log:, clock:, security_only: false)
      @config, @scope, @directory, @log, @clock = config, scope, state_directory, log, clock
      @security_only = security_only
    end

    def call
      journals = Journals.new(@directory)
      journals.with_lock do
        unless journals.pending.empty?
          return { schema: 1, command: "upgrade", status: "needs_reconciliation", components: [],
                   errors: [{ error: "Unfinished upgrades need inspection; run brew-cooldown recover" }] }
        end
        planning = Planning.new(config: @config, scope: @scope, now: @clock.call, log: @log, state_directory: @directory)
        plan = planning.call
        results = []
        errors = plan.fetch(:errors).dup
        # Without all installed consumers, the graph cannot establish that a
        # selected shared dependency is independent of the unreadable package.
        if !planning.inventory.errors.empty? || errors.any? { |entry| entry[:operation] == "inventory_drift" }
          return plan.merge(command: "upgrade", status: "incomplete", execution: [])
        end
        expected = planning.inventory.fingerprint
        planning.resolutions.each do |resolution|
          next unless resolution.status == :resolved
          next if @security_only && resolution.selected.values.none? { |option| option.decision.status == :security_fix }

          directory = journals.component_directory(resolution.selected.keys)
          result = ForkedComponent.call(log: @log) do
            execute_component(planning, resolution, directory, expected)
          end
          unless result["status"] == "completed"
            result["recovery"] ||= recovery_commands(resolution)
          end
          results << result.merge("roots" => resolution.roots.map(&:to_h))
          observed = Prototype::Inventory.capture
          changes = Prototype::Inventory.differences(expected, observed)
          unless changes.all? { |change| owned_change?(change.fetch("path"), resolution, planning.discovery.prepared) }
            errors << { operation: "inventory_drift", error: "Unexpected installed-state change; remaining selections need a fresh plan",
                        changes:, recovery: recovery_commands(resolution) }
            break
          end
          expected = observed
        end
        status = errors.empty? && results.all? { |result| result["status"] == "completed" } ? "completed" : "incomplete"
        plan.merge(command: "upgrade", status:, errors:, execution: results)
      end
    end

    private

    def recovery_commands(resolution)
      resolution.selected.keys.select { |package| package.kind == :formula }.to_h do |package|
        name = "#{package.tap}/#{package.name}"
        [name, Prototype::Recovery.commands(name)]
      end
    end

    def execute_component(planning, resolution, directory, expected)
      Prototype::Execution.check_homebrew!
      observed = Prototype::Inventory.capture
      unless observed == expected
        return { "status" => "drift", "drift" => Prototype::Inventory.differences(expected, observed),
                 "error" => "Installed state changed before candidate revalidation" }
      end
      candidates = resolution.selected.map do |package, option|
        candidate = planning.discovery.prepared[option.release.identity]
        raise Prototype::Refused, "#{package.name}: native execution cannot validate this installed consumer" unless candidate

        candidate
      end
      revalidation = HomebrewAdapter::Revalidation.new(config: @config, inventory: planning.inventory, prepared: planning.discovery.prepared,
                                                       state_directory: @directory, log: @log, clock: @clock)
      revalidation.check!(resolution.selected)
      map = Prototype::ExactMap.new(candidates)
      map.activate
      before_install = lambda do |candidate|
        selection = resolution.selected.select { |package, _option| package.name == candidate.formula.name }
        revalidation.check!(selection, verify_payload: false)
      end
      Prototype::Execution.new(map, state_directory: directory).apply(expected_inventory: expected, before_install:)
    end

    def owned_change?(path, resolution, prepared)
      resolution.selected.values.reject(&:retained).any? do |option|
        formula = prepared.fetch(option.release.identity).formula
        names = [formula.name, *formula.aliases, *formula.oldnames]
        path.start_with?("#{formula.rack}/") || names.any? do |name|
          [HOMEBREW_PREFIX/"opt"/name, HOMEBREW_LINKED_KEGS/name].any? { |allowed| allowed.to_s == path }
        end
      end
    end
  end
end
