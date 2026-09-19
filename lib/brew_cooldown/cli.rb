# frozen_string_literal: true

require "optparse"
require "time"
require_relative "planning"
require_relative "report"
require_relative "recovery"
require_relative "state_directory"
require_relative "upgrade"
require_relative "explanation"

module BrewCooldown
  module CLI
    def self.run(arguments)
      output = STDOUT.dup
      # Native subprocesses inherit descriptors, not Ruby's $stdout variable.
      # Keep their diagnostics off the result stream, including in JSON mode.
      STDOUT.reopen(STDERR)
      options = { installed: false, json: false }
      parser = OptionParser.new do |flags|
        flags.banner = "Usage: brew-cooldown plan|upgrade [scope options] | explain PACKAGE [scope options] | recover [--accept-current DIGEST] [--json]"
        flags.on("--brewfile PATH", "Installed roots from a trusted Brewfile") { |value| options[:brewfile] = value }
        flags.on("--installed", "All installed Homebrew packages") { options[:installed] = true }
        flags.on("--config PATH", "Read configuration from PATH") { |value| options[:config] = value }
        flags.on("--security-only", "Upgrade only components with an evidenced installed security fix") { options[:security_only] = true }
        flags.on("--accept-current DIGEST", "Acknowledge the journal and inventory shown by recover") { |value| options[:accept_current] = value }
        flags.on("--json", "Write the structured result to stdout") { options[:json] = true }
        flags.on("-h", "--help", "Show supported command options") do
          output.puts(flags)
          return 0
        end
      end
      command = arguments.first && !arguments.first.start_with?("-") ? arguments.shift : "plan"
      parser.parse!(arguments)
      requested = arguments.shift if command == "explain"
      raise ConfigurationError, "explain requires a package name" if command == "explain" && !requested
      raise ConfigurationError, "Unexpected arguments: #{arguments.join(' ')}" unless arguments.empty?
      raise ConfigurationError, "Command #{command.inspect} is not available; this build supports plan, upgrade, explain and recover" unless %w[plan upgrade explain recover].include?(command)

      log = ->(**event) { warn JSON.generate(event) }
      if command == "recover"
        raise ConfigurationError, "recover does not take scope or configuration options" if
          options[:brewfile] || options[:installed] || options[:config] || options[:security_only]
        result = Recovery.new(state_directory: StateDirectory.path, log:).call(accept_current: options[:accept_current])
      else
        raise ConfigurationError, "--accept-current belongs to recover" if options[:accept_current]

        config = Config.load(options[:config])
        scope = config.selected_scope(brewfile: options[:brewfile], installed: options[:installed])
        if command == "upgrade"
          result = Upgrade.new(config:, scope:, log:, state_directory: StateDirectory.path,
                               clock: -> { Time.now.utc }, security_only: options.fetch(:security_only, false)).call
        else
          raise ConfigurationError, "--security-only belongs to upgrade" if options[:security_only]

          planning = Planning.new(config:, scope:, now: Time.now.utc, log:, state_directory: StateDirectory.path)
          result = planning.call
          if command == "explain"
            result = Explanation.call(result, requested:, installed: planning.inventory.records.values.map(&:installed))
          end
        end
      end
      if options[:json]
        output.puts(JSON.pretty_generate(Report.json_value(result)))
      else
        case command
        when "recover" then Report.print_recovery(result, output)
        when "upgrade" then Report.print_upgrade(result, output)
        when "explain" then Report.print_explanation(result, output)
        else Report.print_human(result, output)
        end
      end
      %w[assessed completed idle accepted_current].include?(result[:status]) ? 0 : 1
    rescue StandardError => error
      diagnostic = { schema: 1, status: "error", operation: command || "parse_arguments", error: error.message,
                     error_class: error.class.name, backtrace: error.backtrace }
      warn JSON.generate(diagnostic)
      output.puts(options&.fetch(:json, false) ? JSON.pretty_generate(diagnostic) : "Error: #{error.message}")
      1
    ensure
      output&.close
    end
  end
end

exit BrewCooldown::CLI.run(ARGV)
