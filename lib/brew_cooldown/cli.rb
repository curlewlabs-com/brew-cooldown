# frozen_string_literal: true

require "optparse"
require "time"
require_relative "planning"
require_relative "report"
require_relative "recovery"
require_relative "state_directory"

module BrewCooldown
  module CLI
    def self.run(arguments)
      output = STDOUT.dup
      # Native subprocesses inherit descriptors, not Ruby's $stdout variable.
      # Keep their diagnostics off the result stream, including in JSON mode.
      STDOUT.reopen(STDERR)
      options = { installed: false, json: false }
      parser = OptionParser.new do |flags|
        flags.banner = "Usage: brew-cooldown plan [scope options] | recover [--accept-current DIGEST] [--json]"
        flags.on("--brewfile PATH", "Installed roots from a trusted Brewfile") { |value| options[:brewfile] = value }
        flags.on("--installed", "All installed Homebrew packages") { options[:installed] = true }
        flags.on("--config PATH", "Read configuration from PATH") { |value| options[:config] = value }
        flags.on("--accept-current DIGEST", "Acknowledge the journal and inventory shown by recover") { |value| options[:accept_current] = value }
        flags.on("--json", "Write a structured plan") { options[:json] = true }
        flags.on("-h", "--help", "Show supported command options") do
          output.puts(flags)
          return 0
        end
      end
      command = arguments.first && !arguments.first.start_with?("-") ? arguments.shift : "plan"
      parser.parse!(arguments)
      raise ConfigurationError, "Unexpected arguments: #{arguments.join(' ')}" unless arguments.empty?
      raise ConfigurationError, "Command #{command.inspect} is not available; this build supports plan and recover" unless %w[plan recover].include?(command)

      log = ->(**event) { warn JSON.generate(event) }
      if command == "recover"
        raise ConfigurationError, "recover does not take scope or configuration options" if
          options[:brewfile] || options[:installed] || options[:config]
        result = Recovery.new(state_directory: StateDirectory.path, log:).call(accept_current: options[:accept_current])
      else
        raise ConfigurationError, "--accept-current belongs to recover" if options[:accept_current]

        config = Config.load(options[:config])
        scope = config.selected_scope(brewfile: options[:brewfile], installed: options[:installed])
        result = Planning.new(config:, scope:, now: Time.now.utc, log:, state_directory: StateDirectory.path).call
      end
      if options[:json]
        output.puts(JSON.pretty_generate(Report.json_value(result)))
      else
        command == "recover" ? Report.print_recovery(result, output) : Report.print_human(result, output)
      end
      %w[assessed idle accepted_current].include?(result[:status]) ? 0 : 1
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
