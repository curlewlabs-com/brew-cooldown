# frozen_string_literal: true

require "utils/curl"
require "uri"
require_relative "../policy"
require_relative "registry_transport"
require "pkg_version"

module BrewCooldown
  module HomebrewAdapter
    module CurrentFormula
      def self.fetch(name, log:)
        url = "https://formulae.brew.sh/api/formula/#{URI.encode_www_form_component(name)}.json"
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
