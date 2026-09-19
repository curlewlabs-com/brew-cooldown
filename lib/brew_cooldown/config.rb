# frozen_string_literal: true

require "json"
require "pathname"
require "digest"
require_relative "policy"

module BrewCooldown
  class ConfigurationError < StandardError; end

  class Config
    FIELDS = { "patch_days" => :patch, "minor_days" => :minor, "major_days" => :major, "default_days" => :default }.freeze
    IDENTITY = /\A(formula|cask):[a-z0-9_-]+\/[a-z0-9_-]+\/[a-z0-9][a-z0-9+@._-]*\z/

    attr_reader :scope, :max_assignments, :digest

    def self.load(path = nil, environment: ENV)
      explicit = !path.nil?
      root = environment.fetch("HOMEBREW_COOLDOWN_CONFIG_HOME") { environment.fetch("XDG_CONFIG_HOME") { File.join(Dir.home, ".config") } }
      path ||= Pathname(root)/"brew-cooldown/config.json"
      path = Pathname(path).expand_path
      data = if path.file?
        JSON.parse(path.read)
      elsif explicit
        raise ConfigurationError, "Configuration file not found: #{path}"
      else
        {}
      end
      new(data, directory: path.dirname, source_path: path)
    rescue JSON::ParserError, SystemCallError => error
      raise ConfigurationError, "Cannot read configuration #{path}: #{error.message}"
    end

    def initialize(data, directory:, source_path: nil)
      @source_path = source_path
      object!(data, %w[cooldown packages scope solver], "configuration")
      @global = cooldown(data.fetch("cooldown", {}))
      packages = data.fetch("packages", {})
      raise ConfigurationError, "packages must be an object" unless packages.is_a?(Hash)

      @packages = packages.to_h do |identity, values|
        raise ConfigurationError, "Expected a canonical package identity: #{identity}" unless IDENTITY.match?(identity)

        [identity, cooldown(values)]
      end
      @scope = parse_scope(data.fetch("scope", {}), directory:)
      solver = data.fetch("solver", {})
      object!(solver, ["max_assignments"], "solver")
      @max_assignments = solver.fetch("max_assignments", 100_000)
      raise ConfigurationError, "solver.max_assignments must be a positive integer" unless
        max_assignments.is_a?(Integer) && max_assignments.positive?

      @digest = Digest::SHA256.hexdigest(JSON.generate(data))
    end

    def delays(package)
      @global.merge(@packages.fetch("#{package.kind}:#{package.tap}/#{package.name}", {}))
    end

    def verify_current!
      return unless @source_path

      current = @source_path.file? ? JSON.parse(@source_path.read) : {}
      unless Digest::SHA256.hexdigest(JSON.generate(current)) == digest
        raise ConfigurationError, "Configuration changed during planning; rerun with the current policy"
      end
    rescue JSON::ParserError, SystemCallError => error
      raise ConfigurationError, "Cannot revalidate configuration #{@source_path}: #{error.message}"
    end

    def selected_scope(brewfile: nil, installed: false, directory: Pathname.pwd)
      raise ConfigurationError, "Choose --brewfile or --installed" if brewfile && installed
      return { installed: true } if installed
      return { brewfile: Pathname(brewfile).expand_path(directory) } if brewfile
      raise ConfigurationError, "Specify --brewfile, --installed or a configured scope" if scope.empty?

      scope
    end

    private

    def object!(value, allowed, label)
      raise ConfigurationError, "#{label} must be an object" unless value.is_a?(Hash)

      unknown = value.keys - allowed
      raise ConfigurationError, "Unknown #{label} keys: #{unknown.join(', ')}" unless unknown.empty?
    end

    def cooldown(values)
      object!(values, FIELDS.keys, "cooldown")
      values.to_h do |field, days|
        raise ConfigurationError, "#{field} must be nonnegative integer days" unless days.is_a?(Integer) && days >= 0

        [FIELDS.fetch(field), days]
      end
    end

    def parse_scope(value, directory:)
      object!(value, %w[brewfile installed], "scope")
      raise ConfigurationError, "Scope cannot contain both brewfile and installed" if value.size > 1
      return {} if value.empty?
      if value.key?("installed")
        raise ConfigurationError, "scope.installed must be true" unless value["installed"] == true

        return { installed: true }
      end
      path = value["brewfile"]
      raise ConfigurationError, "scope.brewfile must be a nonempty path" unless path.is_a?(String) && !path.empty?

      { brewfile: Pathname(path).expand_path(directory) }
    end
  end
end
