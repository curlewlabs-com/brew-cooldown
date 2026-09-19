# frozen_string_literal: true

module BrewCooldown
  module HomebrewAdapter
    module Compatibility
      def self.call(requirement, option)
        required = requirement.build
        selected = option.release.build
        return true if required.version == selected.version && required.revision == selected.revision &&
                       required.rebuild == selected.rebuild

        cohort = requirement.compatibility_version
        cohort.is_a?(Integer) && cohort.positive? && cohort == option.compatibility_version
      end
    end
  end
end
