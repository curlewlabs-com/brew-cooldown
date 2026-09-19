# frozen_string_literal: true

require "utils/curl"
require "resource"
require "digest"
require "json"
require "uri"

module BrewCooldown
  module HomebrewAdapter
    class RegistryError < StandardError; end
    RegistryResponse = Data.define(:body, :headers)

    class RegistryTransport
      ROOT = "https://ghcr.io/v2/homebrew/core"
      ACCEPT = "application/vnd.oci.image.index.v1+json, application/vnd.oci.image.manifest.v1+json"

      def initialize(log:)
        @log = log
      end

      def fresh(url)
        validate_url!(url)
        @log.call(operation: "read_registry", url:)
        # This is Homebrew's anonymous public-registry credential. A configured
        # private mirror's authorization must never be sent to the public host.
        result = Utils::Curl.curl_output("--silent", "--show-error", "--dump-header", "-",
                                        "--header", "Authorization: Bearer QQ==",
                                        "--header", "Accept: #{ACCEPT}", url, show_output: false)
        parsed = Utils::Curl.parse_curl_output(result.stdout)
        response = parsed.fetch(:responses).last
        unless result.success? && response && response.fetch(:status_code) == "200"
          raise RegistryError, "Registry request failed for #{url}: HTTP #{response&.fetch(:status_code)}"
        end

        RegistryResponse.new(body: parsed.fetch(:body), headers: response.fetch(:headers))
      end

      def immutable(name:, digest:)
        raise RegistryError, "Invalid immutable digest" unless digest.is_a?(String) && digest.match?(/\A[0-9a-f]{64}\z/)

        url = "#{ROOT}/#{GitHubPackages.image_formula_name(name)}/manifests/sha256:#{digest}"
        validate_url!(url)
        @log.call(operation: "read_registry_manifest", package: name, digest:)
        resource = Resource.new("#{name}-#{digest}")
        resource.url(url, using: CurlGitHubPackagesDownloadStrategy, headers: ["Accept: #{ACCEPT}"])
        resource.version(digest)
        resource.checksum = Checksum.new(digest)
        path = resource.fetch
        raise RegistryError, "Immutable manifest checksum differs for #{name}" unless Digest::SHA256.file(path).hexdigest == digest

        JSON.parse(path.read)
      rescue JSON::ParserError => error
        raise RegistryError, "Invalid immutable JSON for #{name}: #{error.message}"
      end

      private

      def validate_url!(url)
        uri = URI.parse(url)
        unless uri.scheme == "https" && uri.host == "ghcr.io" && uri.port == 443 &&
               uri.userinfo.nil? && uri.fragment.nil? && uri.path.start_with?("/v2/homebrew/core/")
          raise RegistryError, "Unexpected registry destination"
        end
      rescue URI::InvalidURIError => error
        raise RegistryError, "Invalid registry destination: #{error.message}"
      end
    end
  end
end
