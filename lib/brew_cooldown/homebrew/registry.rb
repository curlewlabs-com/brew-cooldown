# frozen_string_literal: true

require "github_packages"
require "set"
require_relative "registry_transport"
require_relative "registry_metadata"

module BrewCooldown
  module HomebrewAdapter
    class Registry
      def initialize(transport:)
        @transport = transport
      end

      def tags(name, page_size: 1000)
        image = image_name(name)
        raise ArgumentError, "Page size must be a positive integer" unless page_size.is_a?(Integer) && page_size.positive?

        path = "/v2/homebrew/core/#{image}/tags/list"
        url = "https://ghcr.io#{path}?n=#{page_size}"
        visited = Set.new
        tags = Set.new
        while url
          raise RegistryError, "Registry pagination repeated a page for #{name}" unless visited.add?(url)

          response = @transport.fresh(url)
          body = JSON.parse(response.body)
          unless body.is_a?(Hash) && body["name"] == "homebrew/core/#{image}" && body["tags"].is_a?(Array) &&
                 body["tags"].all? { |tag| tag.is_a?(String) && tag.match?(/\A[a-zA-Z0-9_][a-zA-Z0-9._-]{0,127}\z/) }
            raise RegistryError, "Invalid tag list for #{name}"
          end
          tags.merge(body.fetch("tags"))
          url = next_page(response.headers["link"], current: url, path:)
        end
        tags.to_a.freeze
      rescue JSON::ParserError => error
        raise RegistryError, "Invalid registry tag JSON for #{name}: #{error.message}"
      end

      def resolve(name, tag, platform: nil)
        image = image_name(name)
        unless tag.is_a?(String) && tag.match?(/\A[a-zA-Z0-9_][a-zA-Z0-9._-]{0,127}\z/)
          raise RegistryError, "Invalid registry tag"
        end
        response = @transport.fresh("#{RegistryTransport::ROOT}/#{image}/manifests/#{tag}")
        digest = response.headers["docker-content-digest"]
        unless digest.is_a?(String) && digest.match?(/\Asha256:[0-9a-f]{64}\z/) &&
               "sha256:#{Digest::SHA256.hexdigest(response.body)}" == digest
          raise RegistryError, "Mutable tag response has no matching immutable digest for #{name} #{tag}"
        end
        index_sha256 = digest.delete_prefix("sha256:")
        index = @transport.immutable(name:, digest: index_sha256)
        metadata = RegistryMetadata.new(name:, tag:, platform:, index:, index_sha256:)
        manifest = @transport.immutable(name:, digest: metadata.platform_sha256)
        metadata.complete(manifest)
      end

      private

      def image_name(name)
        unless name.is_a?(String) && name.match?(/\A[a-z0-9][a-z0-9+@._-]*\z/) && !name.include?("..")
          raise RegistryError, "Expected an unqualified core formula name"
        end

        GitHubPackages.image_formula_name(name)
      end

      def next_page(link, current:, path:)
        return if link.nil?

        match = link.is_a?(String) && /\A\s*<([^<>]+)>;\s*rel="next"\s*\z/.match(link)
        raise RegistryError, "Unsupported registry pagination link" unless match

        uri = URI.join(current, match[1])
        unless uri.scheme == "https" && uri.host == "ghcr.io" && uri.port == 443 && uri.path == path &&
               uri.userinfo.nil? && uri.fragment.nil?
          raise RegistryError, "Registry pagination left the package's official history"
        end
        uri.to_s
      rescue URI::InvalidURIError => error
        raise RegistryError, "Invalid pagination destination: #{error.message}"
      end
    end
  end
end
