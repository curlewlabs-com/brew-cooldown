# frozen_string_literal: true

require "utils/curl"
require "uri"
require "tmpdir"
require_relative "../policy"
require_relative "registry_transport"
require "pkg_version"

module BrewCooldown
  module HomebrewAdapter
    module CurrentFormula
      API = "https://formulae.brew.sh/api/formula"
      NAME = /\A[a-z0-9][a-z0-9+@._-]*\z/

      def self.fetch(name, log:)
        url = "#{API}/#{URI.encode_www_form_component(name)}.json"
        log.call(operation: "read_current_formula", package: name, url:)
        result = Utils::Curl.curl_output("--silent", "--show-error", "--dump-header", "-", url, show_output: false)
        parsed = Utils::Curl.parse_curl_output(result.stdout)
        response = parsed.fetch(:responses).last
        unless result.success? && response && response[:status_code] == "200"
          raise RegistryError, "Current formula request failed for #{name}: HTTP #{response&.fetch(:status_code)}"
        end
        validate(JSON.parse(parsed.fetch(:body)), name:)
      rescue JSON::ParserError => error
        raise RegistryError, "Invalid current formula JSON for #{name}: #{error.message}"
      end

      # One curl process reads the whole scope over shared connections. Read
      # one at a time, a process start and a TLS handshake per formula made
      # this the longest part of assessing an up-to-date Brewfile. A package
      # whose read fails keeps its own error; the others are unaffected.
      def self.fetch_all(names, log:, transfer: method(:transfer))
        names = names.uniq
        invalid = names.reject { |name| name.is_a?(String) && name.match?(NAME) && !name.include?("..") }
        raise RegistryError, "Expected unqualified core formula names: #{invalid.join(', ')}" unless invalid.empty?
        return {} if names.empty?

        log.call(operation: "read_current_formulae", packages: names.length, url: API)
        Dir.mktmpdir("brew-cooldown-current-") do |directory|
          requests = names.to_h { |name| [name, ["#{API}/#{URI.encode_www_form_component(name)}.json", File.join(directory, "#{name}.json")]] }
          statuses = transfer.call(requests.values)
          requests.to_h do |name, (_url, path)|
            [name, outcome(name, path, statuses[path])]
          end
        end
      end

      def self.transfer(requests)
        arguments = ["--silent", "--show-error", "--parallel", "--parallel-max", "16",
                     "--write-out", "%{filename_effective}\\t%{response_code}\\n"]
        requests.each { |url, path| arguments.push("--output", path, url) }
        # Without --fail a missing formula still produces its status line, and
        # one failed transfer cannot discard the completed ones.
        result = Utils::Curl.curl_output(*arguments, connect_timeout: 15, max_time: 120)
        result.stdout.lines.filter_map { |line| line.chomp.split("\t", 2) if line.include?("\t") }.to_h
      end
      private_class_method :transfer

      def self.outcome(name, path, status)
        unless status == "200"
          return RegistryError.new("Current formula request failed for #{name}: HTTP #{status || 'no response'}")
        end

        validate(JSON.parse(File.read(path)), name:)
      rescue JSON::ParserError => error
        RegistryError.new("Invalid current formula JSON for #{name}: #{error.message}")
      rescue RegistryError, SystemCallError => error
        error
      end
      private_class_method :outcome

      def self.validate(data, name:)
        unless data.is_a?(Hash) && data["name"] == name && data["tap"] == "homebrew/core" &&
               data["version_scheme"].is_a?(Integer) && data["version_scheme"] >= 0 &&
               [true, false].include?(data["disabled"])
          raise RegistryError, "Current core identity or version scheme unavailable for #{name}"
        end
        if data.fetch("disabled")
          raise RegistryError, "Homebrew has disabled #{name}: #{data['disable_reason'] || 'no reason supplied'}"
        end
        unless data.dig("versions", "stable").is_a?(String) && !data.dig("versions", "stable").empty? &&
               data["revision"].is_a?(Integer) && data["revision"] >= 0
          raise RegistryError, "Current package version unavailable for #{name}"
        end

        data
      end

      # Homebrew's current build bounds every candidate: verify_candidate!
      # rejects anything ahead of it. With that version and revision installed,
      # no registry tag can advance the package.
      def self.installed?(current, build)
        current.fetch("version_scheme") == build.scheme &&
          PkgVersion.new(Version.new(current.fetch("versions").fetch("stable")), current.fetch("revision")) ==
            PkgVersion.new(Version.new(build.version), build.revision)
      end

      def self.rebuild(current)
        value = current.dig("bottle", "stable", "rebuild")
        value.is_a?(Integer) && value.positive? ? value : 0
      end

      def self.verify_candidate!(current, build)
        scheme_order = build.scheme <=> current.fetch("version_scheme")
        return if scheme_order.negative?

        comparison = PkgVersion.new(Version.new(build.version), build.revision) <=>
                     PkgVersion.new(Version.new(current.fetch("versions").fetch("stable")), current.fetch("revision"))
        return if scheme_order.zero? && comparison.negative?

        current_rebuild = current.dig("bottle", "stable", "rebuild")
        return if scheme_order.zero? && comparison.zero? && current_rebuild.is_a?(Integer) && build.rebuild <= current_rebuild

        raise RegistryError, "#{current.fetch('name')}: candidate exceeds the currently published build; possible rollback or unavailable bottle evidence"
      end
    end
  end
end
