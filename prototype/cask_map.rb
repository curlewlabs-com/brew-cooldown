# frozen_string_literal: true

require "cask/upgrade"
require_relative "cask_candidate"

module BrewCooldown
  module Prototype
    class << self
      attr_accessor :cask_map
    end

    class CaskMap
      def initialize(candidate = nil, predecessor: nil, candidates: nil, predecessors: {})
        entries = candidates || [candidate]
        @candidates = entries.to_h { |entry| [entry.cask.full_name, entry] }
        @predecessors = predecessors.dup
        @predecessors[candidate.cask.full_name] = predecessor if predecessor
        @installed = entries.filter_map do |entry|
          old = @predecessors[entry.cask.full_name] || (entry.cask unless entry.install?)
          [old.installed_caskfile, old] if old&.installed_caskfile
        end.to_h
      end

      def validate(cask)
        selected = @candidates[cask.full_name]
        return if selected && (cask.equal?(selected.cask) || cask.equal?(@predecessors[cask.full_name]))

        raise Refused, "unplanned cask object: #{cask.full_name}"
      end

      def resolve(reference)
        selected = @candidates[reference.to_s.delete_prefix("homebrew/cask/")]
        return selected.cask if selected

        raise Refused, "unplanned cask lookup: #{reference}"
      end

      def installed(path)
        selected = @installed[Pathname(path)]
        raise Refused, "unplanned installed cask lookup: #{path}" unless selected

        selected
      end

      def installation_candidate(cask)
        validate(cask)
        selected = @candidates.fetch(cask.full_name)
        raise Refused, "retained cask cannot be installed outside the plan: #{cask.full_name}" unless selected.install?

        selected
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
        Prototype.cask_map.installation_candidate(cask).verify!
        super
      end

      def dependency_installers(**options)
        unless missing_cask_and_formula_dependencies.empty?
          raise Refused, "cask dependencies must complete their planned operations before installation"
        end

        super
      end

      def install
        unless cask.equal?(Prototype.cask_map.installation_candidate(cask).cask)
          raise Refused, "the installed cask predecessor is not an installation target"
        end

        super
      end

      def stage
        Prototype.cask_map.validate(cask)
        Prototype.cask_map.installation_candidate(cask).verify!
        super
      end
    end
  end
end
