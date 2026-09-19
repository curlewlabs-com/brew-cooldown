# frozen_string_literal: true

require_relative "postinstall"

module BrewCooldown
  module Executor
    # The native formula operation owns installer options, active-keg verification
    # and the paths that pouring and linking this formula may change.
    class FormulaOperation
      attr_reader :candidate

      def initialize(candidate, map:)
        @candidate, @map = candidate, map
      end

      def formula = candidate.formula
      def name = formula.name
      def kind = "formula"
      def key = [kind, formula.full_name]
      def dependencies = candidate.runtime_dependencies.map { |entry| [kind, entry.fetch("full_name").delete_prefix("homebrew/core/")] }

      def record
        verify_before!
        previous = formula.opt_prefix.realpath.to_s if formula.opt_prefix.exist?
        if previous
          installed = Keg.new(Pathname(previous))
          scheme_order = formula.version_scheme <=> installed.version_scheme
          if scheme_order.negative? || (scheme_order.zero? && installed.version >= formula.pkg_version)
            raise Refused, "#{name}: selected version does not advance the active installation"
          end
        end
        { "kind" => kind, "name" => name, "version" => formula.pkg_version.to_s, "previous_keg" => previous,
          "candidate" => candidate.identity, "keg_only" => formula.keg_only?, "status" => "pending" }
      end

      def verify_before!
        raise Refused, "#{name} is pinned" if formula.pinned?
      end

      def install
        Executor.executing_name = name
        # The launcher enables developer mode only to enter `brew ruby`.
        # Its source-cycle diagnostic loads build-only recipes even when
        # pouring bottles. Normal runtime/architecture checks still run.
        with_env(HOMEBREW_DEVELOPER: nil) do
          Postinstall.with_map(@map) do
            existing = formula.opt_prefix.exist?
            requested = existing && Tab.for_keg(Keg.new(formula.opt_prefix.realpath)).installed_on_request
            linked = existing ? formula.linked? : !formula.keg_only?
            installer = FormulaInstaller.new(formula, installed_on_request: requested, link_keg: linked)
            installer.prelude
            installer.fetch
            Homebrew::Install.install_formula(installer, upgrade: formula.opt_prefix.exist?)
          end
        end
        raise Refused, "Homebrew reported failure for #{name}" if Homebrew.failed?
        expected = HOMEBREW_CELLAR/name/formula.pkg_version.to_s
        raise Refused, "#{name}: selected keg is not active" unless formula.opt_prefix.realpath == expected
        raise Refused, "#{name}: installation receipt missing" unless (expected/"INSTALL_RECEIPT.json").file?

        Retained.new(Keg.new(expected)).check_linkage!
      ensure
        Executor.executing_name = nil
      end

      def owns_path?(path)
        names = [name, *formula.aliases, *formula.oldnames]
        path.start_with?("#{formula.rack}/") || names.any? do |entry|
          [HOMEBREW_PREFIX/"opt"/entry, HOMEBREW_LINKED_KEGS/entry].any? { |allowed| allowed.to_s == path }
        end
      end
    end
  end
end
