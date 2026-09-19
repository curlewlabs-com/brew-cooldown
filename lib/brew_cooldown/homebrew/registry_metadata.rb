# frozen_string_literal: true

require "date"
require "time"
require "pkg_version"
require "bottle_specification"

module BrewCooldown
  module HomebrewAdapter
    BottleMetadata = Data.define(:name, :pkg_version, :rebuild, :platform, :index_sha256, :platform_sha256,
                                 :bottle_sha256, :published_at, :runtime_dependencies, :source)

    class RegistryMetadata
      attr_reader :platform_sha256

      def initialize(name:, tag:, platform:, index:, index_sha256:)
        @name, @tag, @index_sha256 = name, tag, index_sha256
        annotations = object!(index, "index").fetch("annotations")
        object!(annotations, "index annotations")
        unless index["schemaVersion"] == 2 && annotations["org.opencontainers.image.title"] == name &&
               annotations["org.opencontainers.image.ref.name"] == tag &&
               annotations["org.opencontainers.image.vendor"] == "homebrew"
          raise RegistryError, "Index identity differs for #{name} #{tag}"
        end
        @version = text!(annotations["org.opencontainers.image.version"], "package version")
        @rebuild = if tag == @version
          0
        elsif tag.start_with?("#{@version}-") && tag.delete_prefix("#{@version}-").match?(/\A[1-9][0-9]*\z/)
          tag.delete_prefix("#{@version}-").to_i
        else
          raise RegistryError, "Index version and rebuild differ for #{name} #{tag}"
        end
        manifests = index["manifests"]
        raise RegistryError, "Index manifests must be objects" unless manifests.is_a?(Array) && manifests.all? { |entry| entry.is_a?(Hash) }

        @platform = platform ? platform.to_s : native_platform(manifests)
        @reference = GitHubPackages.version_rebuild(Version.new(@version), @rebuild, @platform)

        matching = manifests.select { |entry| entry.dig("annotations", "org.opencontainers.image.ref.name") == @reference }
        raise RegistryError, "Missing or ambiguous platform #{@platform} for #{name} #{tag}" unless matching.length == 1

        @descriptor = matching.first
        @platform_sha256 = digest!(@descriptor["digest"], "platform manifest")
      rescue KeyError, TypeError => error
        raise RegistryError, "Invalid registry index: #{error.message}"
      end

      def complete(manifest)
        annotations = object!(manifest, "manifest").fetch("annotations")
        object!(annotations, "manifest annotations")
        unless manifest["schemaVersion"] == 2 && annotations["org.opencontainers.image.ref.name"] == @reference &&
               annotations["org.opencontainers.image.version"] == @version &&
               annotations["org.opencontainers.image.title"] == "#{@name} #{@reference}" &&
               annotations["org.opencontainers.image.vendor"] == "homebrew"
          raise RegistryError, "Platform manifest identity differs for #{@name} #{@tag}"
        end
        layers = manifest["layers"]
        unless layers.is_a?(Array) && layers.length == 1 && layers.first.is_a?(Hash)
          raise RegistryError, "Unexpected bottle layers for #{@name} #{@tag}"
        end
        bottle_sha256 = digest!(layers.first["digest"], "bottle layer")
        descriptor_annotations = object!(@descriptor.fetch("annotations"), "descriptor annotations")
        unless annotations["sh.brew.bottle.digest"] == bottle_sha256 &&
               descriptor_annotations["sh.brew.bottle.digest"] == bottle_sha256
          raise RegistryError, "Bottle layer and annotations disagree for #{@name} #{@tag}"
        end
        tab = JSON.parse(text!(annotations["sh.brew.tab"], "runtime receipt"))
        object!(tab, "runtime receipt")
        dependencies = tab["runtime_dependencies"]
        unless dependencies.is_a?(Array) && dependencies.all? { |dependency| dependency.is_a?(Hash) }
          raise RegistryError, "Runtime dependencies must be objects for #{@name} #{@tag}"
        end
        unless JSON.parse(text!(descriptor_annotations["sh.brew.tab"], "descriptor receipt")) == tab
          raise RegistryError, "Descriptor and platform runtime receipts differ for #{@name} #{@tag}"
        end
        published_at = annotations["org.opencontainers.image.created"]
        if published_at
          DateTime.rfc3339(text!(published_at, "publication timestamp"))
          published_at = Time.iso8601(published_at).utc
        end
        BottleMetadata.new(name: @name, pkg_version: @version, rebuild: @rebuild, platform: @platform,
                           index_sha256: @index_sha256, platform_sha256:, bottle_sha256:, published_at:,
                           runtime_dependencies: dependencies.freeze, source: annotations["org.opencontainers.image.source"])
      rescue KeyError, TypeError, JSON::ParserError, ArgumentError => error
        raise RegistryError, "Invalid platform metadata for #{@name} #{@tag}: #{error.message}"
      end

      private

      def native_platform(manifests)
        specification = BottleSpecification.new
        manifests.each do |entry|
          annotations = object!(entry["annotations"], "platform annotations")
          reference = text!(annotations["org.opencontainers.image.ref.name"], "platform reference")
          prefix = "#{@version}."
          suffix = @rebuild.positive? ? ".#{@rebuild}" : ""
          next unless reference.start_with?(prefix) && reference.end_with?(suffix)

          tag = reference.delete_prefix(prefix).delete_suffix(suffix)
          digest = digest!("sha256:#{annotations['sh.brew.bottle.digest']}", "bottle annotation")
          specification.sha256(tag.to_sym => digest)
        end
        selected = specification.tag_specification_for(Utils::Bottles.tag)
        raise RegistryError, "No native-compatible bottle for #{@name} #{@tag}" unless selected

        selected.tag.to_s
      end

      def object!(value, field)
        raise RegistryError, "#{field} must be an object" unless value.is_a?(Hash)

        value
      end

      def text!(value, field)
        raise RegistryError, "#{field} must be nonempty text" unless value.is_a?(String) && !value.empty?

        value
      end

      def digest!(value, field)
        raise RegistryError, "Invalid #{field} digest" unless value.is_a?(String) && value.match?(/\Asha256:[0-9a-f]{64}\z/)

        value.delete_prefix("sha256:")
      end
    end
  end
end
