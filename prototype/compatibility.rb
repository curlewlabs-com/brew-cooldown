# frozen_string_literal: true

require_relative "candidate"
require "open3"
require "linkage_checker"

module BrewCooldown
  module Prototype
    module Compatibility
      def self.validate!(dependency, selected)
        version_matches = dependency.fetch("pkg_version") == selected.formula.pkg_version.to_s
        required_rebuild = dependency["bottle_rebuild"]
        rebuild_matches = required_rebuild.is_a?(Integer) && selected.rebuild.is_a?(Integer) &&
                          required_rebuild == selected.rebuild
        return if version_matches && rebuild_matches

        required = dependency["compatibility_version"]
        return if required.is_a?(Integer) && required == selected.compatibility_version

        raise Refused, "#{selected.formula.name} #{selected.formula.pkg_version}: " \
                       "no compatibility evidence for consumer built with #{dependency.fetch('pkg_version')}"
      end
    end

    # The installed receipt supplies the consumer's build requirements; current
    # API metadata cannot retroactively establish those requirements.
    class Retained
      attr_reader :formula, :runtime_dependencies, :rebuild, :keg, :compatibility_version

      def initialize(keg)
        @keg = keg
        name = keg.name
        path = keg/".brew/#{name}.rb"
        @contents = path.read
        @formula = Formulary.from_contents(name, path, @contents, tap: CoreTap.instance, from_metadata: true)
        tab = Tab.for_keg(keg)
        raise Refused, "#{name}: installed recipe differs from keg" unless formula.pkg_version == keg.version
        raise Refused, "#{name}: installed recipe is not from homebrew/core" unless tab.tap == "homebrew/core"

        @runtime_dependencies = tab.runtime_dependencies
        raise Refused, "#{name}: missing installed dependency metadata" unless runtime_dependencies.is_a?(Array)

        # Embedded recipes can omit or predate bottle metadata. Their default
        # rebuild is not evidence of the installed artifact's rebuild.
        @rebuild = nil
        # Homebrew can leave this field null in a poured receipt even when
        # the installed bottle's embedded recipe declares compatibility.
        # This is the recipe in the installed keg, never today's API recipe.
        @compatibility_version = formula.compatibility_version
        recorded = tab.source.dig("versions", "compatibility_version")
        if recorded && recorded != compatibility_version
          raise Refused, "#{name}: installed recipe and receipt disagree about compatibility"
        end
      end

      def install?
        false
      end

      def worker_record
        {
          "name" => formula.name, "version" => formula.pkg_version.to_s, "path" => formula.path.to_s,
          "recipe" => @contents, "recipe_sha256" => Digest::SHA256.hexdigest(@contents)
        }
      end

      def check_candidate!(selected)
        dependency = runtime_dependencies.find { |record| record.fetch("full_name") == selected.formula.full_name }
        return unless dependency

        Compatibility.validate!(dependency, selected)
        required_paths = []
        keg.find do |path|
          next unless path.file? && !path.symlink?

          binary = BinaryPathname.wrap(path)
          next unless binary.dylib? || binary.binary_executable? || binary.mach_o_bundle?
          next unless binary.arch_compatible?(Hardware::CPU.arch)

          binary.dynamically_linked_libraries(except: :DYLIB_USE_WEAK_LINK).each do |library|
            prefix = "#{selected.formula.opt_prefix}/"
            required_paths << library.delete_prefix(prefix) if library.start_with?(prefix)
          end
        end
        return if required_paths.empty?

        selected.bottle.with_verified_snapshot(selected.bottle.cached_download) do |snapshot|
          listing, status = Open3.capture2("/usr/bin/tar", "-tf", snapshot.to_s)
          raise Refused, "#{selected.formula.name}: cannot inspect candidate library paths" unless status.success?

          files = listing.lines.map(&:chomp)
          required_paths.uniq.each do |path|
            expected = "#{selected.formula.name}/#{selected.formula.pkg_version}/#{path}"
            raise Refused, "#{formula.name} needs missing candidate library #{path}" unless files.include?(expected)
          end
        end
      end

      def check_linkage!
        CacheStoreDatabase.use(:linkage) do |database|
          checker = LinkageChecker.new(keg, formula, cache_db: database, rebuild_cache: true)
          raise Refused, "#{formula.name}: broken installed library linkage" if checker.broken_library_linkage?
        end
      end
    end
  end
end
