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
               data["version"].is_a?(String) && !data["version"].empty? && data["version"] != "latest" &&
               [true, false].include?(data["disabled"]) && data["tap_git_head"].is_a?(String) &&
               data["tap_git_head"].match?(/\A[0-9a-f]{40}\z/) && data["ruby_source_path"] == "Casks/#{name[0]}/#{name}.rb"
          raise RegistryError, "Current official cask identity or immutable source unavailable for #{name}"
        end
        raise RegistryError, "Homebrew has disabled #{name}: #{data['disable_reason'] || 'no reason supplied'}" if data.fetch("disabled")

        data
      end

      def self.verify_candidate!(current, version)
        if Version.new(version) > Version.new(current.fetch("version"))
          raise RegistryError, "#{current.fetch('token')}: historical candidate exceeds current cask version; possible rollback"
        end
      end
    end
  end
end
