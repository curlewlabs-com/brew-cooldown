# frozen_string_literal: true

require "time"

module BrewCooldown
  module Report
    def self.print_recovery(result, output)
      output.puts("Homebrew cooldown recovery: #{result.fetch(:status)}")
      output.puts(result[:message]) if result[:message]
      output.puts("Error: #{result[:error]}") if result[:error]
      output.puts("Journal: #{result[:journal]}") if result[:journal]
      Array(result[:drift]).each do |change|
        output.puts("Changed #{change.fetch('path')}: expected #{change['expected'].inspect}, observed #{change['observed'].inspect}")
      end
      Array(result[:operations]).each do |operation|
        output.puts("#{operation.fetch('name')} #{operation.fetch('version')}: #{operation.fetch('status')}")
        output.puts("  Previous keg: #{operation['previous_keg']}") if operation['previous_keg']
        output.puts("  Error: #{operation['error']}") if operation['error']
        Array(operation['recovery']).each do |choice|
          output.puts("  #{choice.fetch('purpose')}:\n    #{choice.fetch('command')}")
        end
      end
      if (choice = result[:accept_current])
        output.puts("#{choice.fetch('purpose')}:\n  #{choice.fetch('command')}")
      end
    end

    def self.print_human(result, output)
      output.puts("Homebrew cooldown plan: #{result.fetch(:status)}")
      result.fetch(:scope).each do |entry|
        output.puts("#{entry.fetch(:requested)}: #{entry.fetch(:status)}#{entry[:reason] ? " - #{entry[:reason]}" : ''}")
      end
      result.fetch(:components).each do |component|
        component.fetch(:selected).each do |selection|
          next if selection.fetch(:operation) == "retain"

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
