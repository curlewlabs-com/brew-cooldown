# frozen_string_literal: true

require "cask/upgrade"
require_relative "cask_candidate"

module BrewCooldown
  module Prototype
    class << self
      attr_accessor :cask_map
    end

    class CaskMap
      attr_reader :candidate, :predecessor

      def initialize(candidate, predecessor: nil)
        @candidate, @predecessor = candidate, predecessor
        @installed_path = predecessor&.installed_caskfile
      end

      def validate(cask)
        return if cask.equal?(candidate.cask) || (predecessor && cask.equal?(predecessor))

        raise Refused, "unplanned cask object: #{cask.full_name}"
      end

      def resolve(reference)
        return candidate.cask if reference.equal?(candidate.cask) ||
          [candidate.cask.token, "homebrew/cask/#{candidate.cask.token}"].include?(reference.to_s)

        raise Refused, "unplanned cask lookup: #{reference}"
      end

      def installed(path)
        raise Refused, "unplanned installed cask lookup: #{path}" unless predecessor && Pathname(path) == @installed_path

        predecessor
      end

      def activate
        raise Refused, "cask map already active" if Prototype.cask_map

        Prototype.cask_map = self
        Cask::CaskLoader.singleton_class.prepend(CaskResolverGuard)
        Cask::Installer.prepend(CaskInstallerGuard)
      end
    end

    module CaskResolverGuard
      def load(reference, config: nil, warn: true)
        Prototype.cask_map.resolve(reference)
      end

      def load_from_installed_caskfile(path, **options)
        Prototype.cask_map.installed(path)
      end
    end

    module CaskInstallerGuard
      def initialize(cask, **options)
        Prototype.cask_map.validate(cask)
        if options[:force] || options[:adopt] || options[:skip_cask_deps] || options[:zap] ||
           options[:verify_download_integrity] == false || options[:installed_on_request] == false
          raise Refused, "cask installation options bypass the selected operation"
        end
        super
      end

      def prelude
        Prototype.cask_map.validate(cask)
        Prototype.cask_map.candidate.verify!
        super
      end

      def dependency_installers(**options)
        unless missing_cask_and_formula_dependencies.empty?
          raise Refused, "cask dependencies must complete their planned operations before installation"
        end

        super
      end

      def install
        unless cask.equal?(Prototype.cask_map.candidate.cask)
          raise Refused, "the installed cask predecessor is not an installation target"
        end

        super
      end

      def stage
        Prototype.cask_map.validate(cask)
        Prototype.cask_map.candidate.verify!
        super
      end
    end
  end
end
