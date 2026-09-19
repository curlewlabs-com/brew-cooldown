# frozen_string_literal: true

require "version"
require "pkg_version"

module BrewCooldown
  module HomebrewAdapter
    module BuildOrder
      def self.call(left, right)
        scheme = left.scheme <=> right.scheme
        return scheme unless scheme.zero?

        version = PkgVersion.new(Version.new(left.version), left.revision) <=>
                  PkgVersion.new(Version.new(right.version), right.revision)
        version.zero? ? left.rebuild <=> right.rebuild : version
      end
    end
  end
end
