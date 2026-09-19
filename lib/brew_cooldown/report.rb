# frozen_string_literal: true

require "time"

module BrewCooldown
  module Report
    def self.print_explanation(result, output)
      explanation = result.fetch(:explanation)
      output.puts("Explanation for #{explanation.fetch(:requested)}: #{explanation.fetch(:status)}")
      output.puts(explanation[:reason]) if explanation[:reason]
      package = explanation[:package]
      if (baseline = explanation[:installed])
        build = baseline.fetch(:build).to_h
        output.puts("Installed: #{build.fetch(:version)} (revision #{build.fetch(:revision)}, rebuild #{build[:rebuild] || 'unknown'})")
      end
      result.fetch(:candidates).select { |entry| entry.fetch(:package) == package }.each do |candidate|
        decision = candidate.fetch(:decision)
        output.puts("Candidate #{candidate.fetch(:build).fetch(:version)} [#{candidate.fetch(:identity)}]: #{decision.fetch(:status)} - #{decision.fetch(:reason)}")
        output.puts("  Cooldown class: #{decision[:delay_kind]}; age source: #{decision[:age_source]}")
        output.puts("  Eligible at: #{decision[:eligible_at].getutc.iso8601}") if decision[:eligible_at]
        fixes = decision.fetch(:fixed_advisories)
        output.puts("  Fixed advisories: #{fixes.join(', ')}") unless fixes.empty?
        output.puts("  Security coverage: #{candidate.fetch(:security).fetch(:coverage)}")
      end
      components = result.fetch(:components).select do |component|
        component.fetch(:roots).include?(package) || component.fetch(:selected).any? { |entry| entry.fetch(:package) == package }
      end
      components.each do |component|
        reason = component[:reason] ? " - #{component[:reason]}" : ""
        output.puts("Dependency component: #{component.fetch(:status)}#{reason}")
      end
      identities = components.flat_map { |component| component.fetch(:rejected_options).keys }
      # Preserve errors for the full assessment even when narrowing its display;
      # unrelated failures must not become successful package explanations.
      focused = result.merge(
        scope: result.fetch(:scope).select { |entry| package && entry[:package] == package },
        components:,
        candidates: result.fetch(:candidates).select { |entry| identities.include?(entry.fetch(:identity)) },
        installed_security: result.fetch(:installed_security).select { |entry| entry.fetch(:package) == package },
        diagnostics: Array(result[:diagnostics]).select { |entry| !entry[:package] || entry[:package] == package },
      )
      print_human(focused, output, heading: "Scope assessment")
    end

    def self.print_upgrade(result, output)
      if result[:scope]
        print_human(result, output, heading: "Homebrew cooldown upgrade", show_proposals: false)
      else
        output.puts("Homebrew cooldown upgrade: #{result.fetch(:status)}")
      end
      Array(result[:execution]).each do |component|
        output.puts("Component: #{component.fetch('status')}")
        # A component reuses the journal's operation layout. Its status line
        # is already printed, and a completed upgrade is not a recovery.
        print_recovery(component.transform_keys(&:to_sym), output, heading: nil)
        component.fetch("recovery", {}).each_value do |choices|
          choices.each { |choice| output.puts("#{choice.fetch('purpose')}:\n  #{choice.fetch('command')}") }
        end
      end
      Array(result[:errors]).each { |error| output.puts("Error: #{error[:error] || error[:reason]}") } unless result[:scope]
      if Array(result[:execution]).any? { |component| component["status"] != "completed" } || result[:status] == "needs_reconciliation"
        output.puts("Inspect unfinished work with brew-cooldown recover.")
      end
    end

    def self.print_recovery(result, output, heading: "Homebrew cooldown recovery")
      output.puts("#{heading}: #{result.fetch(:status)}") if heading
      output.puts(result[:message]) if result[:message]
      output.puts("Error: #{result[:error]}") if result[:error]
      output.puts("Journal: #{result[:journal]}") if result[:journal]
      Array(result[:journals]).each { |path| output.puts("Journal: #{path}") }
      Array(result[:drift] || result[:changes]).each do |change|
        output.puts("Changed #{change.fetch('path')}: expected #{change['expected'].inspect}, observed #{change['observed'].inspect}")
      end
      Array(result[:operations]).each do |operation|
        output.puts("#{operation.fetch('kind', 'formula')}/#{operation.fetch('name')} #{operation.fetch('version')}: #{operation.fetch('status')}")
        output.puts("  Previous keg: #{operation['previous_keg']}") if operation['previous_keg']
        output.puts("  Previous version: #{operation['previous_version']}") if operation['previous_version']
        output.puts("  Error: #{operation['error']}") if operation['error']
        Array(operation['recovery']).each do |choice|
          output.puts("  #{choice.fetch('purpose')}:\n    #{choice.fetch('command')}")
        end
      end
      if (choice = result[:accept_current])
        output.puts("#{choice.fetch('purpose')}:\n  #{choice.fetch('command')}")
      end
    end

    def self.print_human(result, output, heading: "Homebrew cooldown plan", show_proposals: true)
      output.puts("#{heading}: #{result.fetch(:status)}")
      result.fetch(:scope).each do |entry|
        output.puts("#{entry.fetch(:requested)}: #{entry.fetch(:status)}#{entry[:reason] ? " - #{entry[:reason]}" : ''}")
      end
      result.fetch(:components).each do |component|
        component.fetch(:selected).each do |selection|
          next if !show_proposals || selection.fetch(:operation) == "retain"

          build = selection.fetch(:build)
          output.puts("Upgrade #{selection.fetch(:package).fetch(:name)} to #{build.fetch(:version)} " \
                      "(revision #{build.fetch(:revision)}, rebuild #{build.fetch(:rebuild)}): #{selection.fetch(:decision).fetch(:reason)}")
        end
        component.fetch(:rejected_options).each do |identity, reason|
          candidate = result.fetch(:candidates).find { |entry| entry.fetch(:identity) == identity }
          label = candidate ? "#{candidate.fetch(:package).fetch(:name)} #{candidate.fetch(:build).fetch(:version)}" : identity
          output.puts("#{label}: #{reason}")
        end
      end
      result.fetch(:candidates).reject { |entry| %i[eligible security_fix].include?(entry.fetch(:decision).fetch(:status)) }.each do |entry|
        decision = entry.fetch(:decision)
        output.puts("#{entry.fetch(:package).fetch(:name)} #{entry.fetch(:build).fetch(:version)}: #{decision.fetch(:reason)}" \
                    "#{decision[:eligible_at] ? " (eligible #{decision[:eligible_at].utc.iso8601})" : ''}")
      end
      result.fetch(:installed_security).each do |assessment|
        output.puts("Security coverage for #{assessment.fetch(:package).fetch(:name)}: #{assessment.fetch(:coverage)}")
      end
      Array(result[:diagnostics]).each do |entry|
        output.puts("Note: #{entry.fetch(:reason)}")
        Array(entry[:recovery]).each do |choice|
          output.puts("  #{choice.fetch('purpose')}:\n    #{choice.fetch('command')}")
        end
      end
      result.fetch(:errors).each do |entry|
        output.puts("Error: #{entry[:error] || entry[:reason]}")
        recoveries = entry[:recovery]
        recoveries = recoveries.values.flatten if recoveries.is_a?(Hash)
        Array(recoveries).each do |recovery|
          next unless recovery.is_a?(Hash) && recovery["command"]

          output.puts("  #{recovery.fetch('purpose')}:\n    #{recovery.fetch('command')}")
        end
      end
    end

    def self.json_value(value)
      case value
      when Time then value.getutc.iso8601(9)
      when Data then json_value(value.to_h)
      when Hash then value.transform_values { |entry| json_value(entry) }
      when Array then value.map { |entry| json_value(entry) }
      else value
      end
    end
  end
end
