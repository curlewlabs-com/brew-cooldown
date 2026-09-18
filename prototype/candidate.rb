# frozen_string_literal: true

require "formula_installer"
require "attestation"
require "digest"

module BrewCooldown
  module Prototype
    class Refused < StandardError; end

    # A fixed official bottle used to probe Homebrew's historical installer.
    # Registry responses stay in Homebrew's cache, not in a project catalog.
    class Candidate
      DOMAIN = "https://ghcr.io/v2/homebrew/core"
      TAG = :arm64_tahoe

      attr_reader :formula, :bottle, :runtime_dependencies

      def initialize(record)
        @name = record.fetch("name")
        @version = record.fetch("version")
        @index_sha256 = record.fetch("index_sha256")
        raise Refused, "unsupported test identity" unless %w[pcre2 ripgrep].include?(@name)
        raise Refused, "invalid index digest" unless @index_sha256.match?(/\A[0-9a-f]{64}\z/)
      end

      def prepare
        # Homebrew may bootstrap gh automatically; the experiment may not add
        # prerequisites outside its fixed package map.
        unless (HOMEBREW_PREFIX/"opt/gh/bin/gh").executable?
          raise Refused, "install gh with Homebrew before running this experiment"
        end

        index = registry_json("manifests", @index_sha256)
        reference = "#{@version}.#{TAG}"
        descriptors = index.fetch("manifests").select do |entry|
          entry.fetch("annotations").fetch("org.opencontainers.image.ref.name") == reference
        end
        raise Refused, "ambiguous or missing platform" unless descriptors.length == 1

        descriptor = descriptors.fetch(0)
        manifest = registry_json("manifests", descriptor.fetch("digest").delete_prefix("sha256:"))
        annotations = manifest.fetch("annotations")
        unless annotations.fetch("org.opencontainers.image.ref.name") == reference
          raise Refused, "platform identity differs"
        end

        layers = manifest.fetch("layers")
        raise Refused, "unexpected bottle layers" unless layers.length == 1

        digest = annotations.fetch("sh.brew.bottle.digest")
        raise Refused, "layer digest differs" unless layers.fetch(0).fetch("digest") == "sha256:#{digest}"

        @runtime_dependencies = JSON.parse(annotations.fetch("sh.brew.tab")).fetch("runtime_dependencies")
        specification = BottleSpecification.new
        specification.root_url(DOMAIN)
        specification.sha256(cellar: HOMEBREW_CELLAR.to_s, TAG => digest)
        staged = Bottle.new(nil, specification, Utils::Bottles.tag(TAG),
                            name: @name, pkg_version: PkgVersion.parse(@version))
        staged.fetch
        # Verify before evaluating the recipe; a matching registry hash alone
        # does not establish that Homebrew's builders produced these bytes.
        Homebrew::Attestation.check_core_attestation(staged)
        staged.with_verified_snapshot(staged.cached_download) do |snapshot|
          contents = Utils::Bottles.formula_contents(snapshot, name: @name)
          @formula = Formulary.from_contents(
            @name, HOMEBREW_CELLAR/@name/@version/".brew/#{@name}.rb", contents,
            tap: CoreTap.instance, from_metadata: true
          )
        end
        unless formula.full_name == @name && formula.pkg_version.to_s == @version
          raise Refused, "recipe identity differs"
        end
        if formula.post_install_defined? || formula.post_install_steps_defined?
          raise Refused, "hook execution is not yet constrained"
        end

        formula.bottle_specification.root_url(DOMAIN)
        formula.bottle_specification.sha256(cellar: HOMEBREW_CELLAR.to_s, TAG => digest)
        @bottle = formula.bottle
        raise Refused, "bottle incompatible with this machine" unless bottle

        # Keep the native Bottle and its dependency reader, but resolve its
        # manifest by immutable digest instead of the moving version tag.
        resource = bottle.github_packages_manifest_resource
        resource.url("#{DOMAIN}/#{@name}/manifests/sha256:#{@index_sha256}",
                     using: CurlGitHubPackagesDownloadStrategy,
                     headers: ["Accept: application/vnd.oci.image.index.v1+json"])
        resource.fetch
        verify_digest(resource.cached_download, @index_sha256)
        unless bottle.tab_attributes.fetch("runtime_dependencies") == runtime_dependencies
          raise Refused, "runtime metadata differs"
        end

        # Native installers may reuse cached downloads without reattesting.
        # The explicit check above therefore applies even to a warm cache.
        Utils::Attestation.check_attestation(bottle)
        puts "Prepared #{@name} #{@version}: verified official bottle and recipe"
        self
      end

      private

      def registry_json(kind, digest)
        raise Refused, "invalid registry digest" unless digest.match?(/\A[0-9a-f]{64}\z/)

        resource = Resource.new("#{@name}-#{digest}")
        resource.url("#{DOMAIN}/#{@name}/#{kind}/sha256:#{digest}",
                     using: CurlGitHubPackagesDownloadStrategy,
                     headers: ["Accept: application/vnd.oci.image.index.v1+json, application/vnd.oci.image.manifest.v1+json"])
        resource.version(@version)
        resource.checksum = Checksum.new(digest)
        path = resource.fetch
        verify_digest(path, digest)
        JSON.parse(path.read)
      end

      def verify_digest(path, expected)
        raise Refused, "registry content digest differs" unless Digest::SHA256.file(path).hexdigest == expected
      end
    end
  end
end
