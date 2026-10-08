# frozen_string_literal: true

require "utils/curl"
require "uri"
require_relative "registry_transport"

module BrewCooldown
  module HomebrewAdapter
    module CurrentCask
      def self.fetch(name, log:)
        url = "https://formulae.brew.sh/api/cask/#{URI.encode_www_form_component(name)}.json"
        log.call(operation: "read_current_cask", package: name, url:)
        result = Utils::Curl.curl_output("--silent", "--show-error", "--dump-header", "-", url, show_output: false)
        parsed = Utils::Curl.parse_curl_output(result.stdout)
        response = parsed.fetch(:responses).last
        unless result.success? && response && response[:status_code] == "200"
          raise RegistryError, "Current cask request failed for #{name}: HTTP #{response&.fetch(:status_code)}"
        end
        validate(JSON.parse(parsed.fetch(:body)), name:)
      rescue JSON::ParserError => error
        raise RegistryError, "Invalid current cask JSON for #{name}: #{error.message}"
      end

      def self.validate(data, name:)
        unless data.is_a?(Hash) && data["token"] == name && data["tap"] == "homebrew/cask" &&
               [true, false].include?(data["disabled"]) && data.key?("auto_updates") &&
               [true, false, nil].include?(data["auto_updates"])
          raise RegistryError, "Current official cask identity or update capability unavailable for #{name}"
        end
        raise RegistryError, "Homebrew has disabled #{name}: #{data['disable_reason'] || 'no reason supplied'}" if data.fetch("disabled")

        # Self-managed casks are not historical execution targets. Homebrew's
        # API emits null when the optional auto_updates stanza is unset.
        return data if data.fetch("auto_updates") == true

        unless data["version"].is_a?(String) && !data["version"].empty? && data["version"] != "latest" &&
               data["tap_git_head"].is_a?(String) && data["tap_git_head"].match?(/\A[0-9a-f]{40}\z/) &&
               data["ruby_source_path"] == "Casks/#{name[0]}/#{name}.rb"
          raise RegistryError, "Current official cask immutable source unavailable for #{name}"
        end
        data
      end

      def self.self_managed_reason
        "Homebrew declares independent update capability; outside cooldown control. " \
          "Homebrew's recorded version may differ from the live application; automatic upgrades are skipped"
      end

      def self.verify_candidate!(current, version)
        raise RegistryError, "#{current.fetch('token')}: #{self_managed_reason}" if current.fetch("auto_updates") == true

        if Version.new(version) > Version.new(current.fetch("version"))
          raise RegistryError, "#{current.fetch('token')}: historical candidate exceeds current cask version; possible rollback"
        end
      end
    end
  end
end
