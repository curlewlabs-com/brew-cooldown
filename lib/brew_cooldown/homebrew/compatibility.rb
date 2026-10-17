# frozen_string_literal: true

require "version"
require "pkg_version"

module BrewCooldown
  module HomebrewAdapter
    module Compatibility
      def self.call(requirement, option)
        return false unless requirement.package == option.release.package
        return true if requirement.is_a?(RuntimeRequirement)

        required = requirement.build
        selected = option.release.build
        # Native installed-dependency requirements use PkgVersion, not the
        # installed bottle's rebuild. This retains the package already there;
        # it does not establish identity or authorize a rebuild-only upgrade.
        return true if option.retained && required.version == selected.version && required.revision == selected.revision

        return true if required.version == selected.version && required.revision == selected.revision &&
                       required.rebuild.is_a?(Integer) && selected.rebuild.is_a?(Integer) &&
                       required.rebuild == selected.rebuild

        cohort = requirement.compatibility_version
        # Homebrew uses nil for absence; zero can be an explicit cohort.
        return false unless cohort.is_a?(Integer) && cohort == option.compatibility_version

        covers?(required, selected)
      end

      # A cohort reaches forward from the build a consumer recorded, never back
      # to an earlier one. Homebrew's audit asks for a cohort bump only when a
      # dependency's version changes: simdutf 9.2.0_1, built as C++20, kept
      # cohort 5 while exporting symbols that 9.2.0 lacks, and node built
      # against 9.2.0_1 failed to load beside 9.2.0.
      def self.covers?(required, selected)
        PkgVersion.new(Version.new(selected.version), selected.revision) >=
          PkgVersion.new(Version.new(required.version), required.revision)
      end
    end
  end
end
