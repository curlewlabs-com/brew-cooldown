# frozen_string_literal: true

require "optparse"
require "time"
require_relative "planning"
require_relative "report"

module BrewCooldown
  module CLI
    def self.run(arguments)
      output = STDOUT.dup
      # Native subprocesses inherit descriptors, not Ruby's $stdout variable.
      # Keep their diagnostics off the result stream, including in JSON mode.
      STDOUT.reopen(STDERR)
      options = { installed: false, json: false }
      parser = OptionParser.new do |flags|
        flags.banner = "Usage: brew-cooldown plan --brewfile PATH | --installed [options]"
        flags.on("--brewfile PATH", "Installed roots from a trusted Brewfile") { |value| options[:brewfile] = value }
        flags.on("--installed", "All installed Homebrew packages") { options[:installed] = true }
        flags.on("--config PATH", "Read configuration from PATH") { |value| options[:config] = value }
        flags.on("--json", "Write a structured plan") { options[:json] = true }
        flags.on("-h", "--help", "Show supported command options") do
          output.puts(flags)
          return 0
        end
      end
      command = arguments.first && !arguments.first.start_with?("-") ? arguments.shift : "plan"
      parser.parse!(arguments)
      raise ConfigurationError, "Unexpected arguments: #{arguments.join(' ')}" unless arguments.empty?
      raise ConfigurationError, "Command #{command.inspect} is not available; this build supports plan" unless command == "plan"

      config = Config.load(options[:config])
      scope = config.selected_scope(brewfile: options[:brewfile], installed: options[:installed])
      prefix_id = Digest::SHA256.hexdigest(HOMEBREW_PREFIX.realpath.to_s)
      state_root = Pathname(ENV.fetch("XDG_STATE_HOME") { File.join(Dir.home, ".local/state") })
      state_directory = state_root/"brew-cooldown"/prefix_id
      log = ->(**event) { warn JSON.generate(event) }
      result = Planning.new(config:, scope:, now: Time.now.utc, log:, state_directory:).call
      if options[:json]
        output.puts(JSON.pretty_generate(Report.json_value(result)))
      else
        Report.print_human(result, output)
      end
      result[:status] == "assessed" ? 0 : 1
    rescue StandardError => error
      diagnostic = { schema: 1, status: "error", operation: "plan", error: error.message,
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
