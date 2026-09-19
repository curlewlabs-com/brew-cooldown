# frozen_string_literal: true

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
        cohort.is_a?(Integer) && cohort == option.compatibility_version
      end
    end
  end
end
