# frozen_string_literal: true

module BrewCooldown
  module Executor
    # Native bookkeeping needs facts about installed kegs, not permission to
    # select another recipe. These queries never use Formulary.factory.
    module InstalledState
      def self.formula(reference)
        name = reference.to_s.delete_prefix("homebrew/core/")
        unless name.match?(/\A[a-z0-9][a-z0-9+@._-]*\z/) && !name.include?("..")
          raise Refused, "invalid installed formula reference: #{reference}"
        end
        raise FormulaUnavailableError, name unless (HOMEBREW_CELLAR/name).directory?

        opt = HOMEBREW_PREFIX/"opt"/name
        raise Refused, "#{name}: installed formula has no active opt link" unless opt.symlink? && opt.exist?

        keg = Keg.new(opt.realpath)
        raise Refused, "#{name}: installed opt link selects another rack" unless keg.name == name

        Retained.new(keg).formula
      end

      def self.siblings(formula)
        seen = Set.new([formula.name])
        pending = [formula]
        found = []
        pending.each do |current|
          current.link_overwrite_related_formula_names.each do |name|
            next unless seen.add?(name)

            installed = begin
              self.formula(name)
            rescue FormulaUnavailableError
              next
            end
            found << installed
            pending << installed
          end
        end
        found.sort_by(&:full_name)
      end

      def self.linked?(reference)
        name = reference.split("/").last
        (HOMEBREW_LINKED_KEGS/name).exist? && (HOMEBREW_PREFIX/"opt"/name).exist?
      end

      def self.executable(name, relative_path)
        opt = HOMEBREW_PREFIX/"opt"/name
        return unless (HOMEBREW_CELLAR/name).directory?

        unless opt.symlink? && opt.exist? && Keg.new(opt.realpath).name == name
          raise Refused, "#{name}: installed helper has no active keg"
        end
        executable = opt/relative_path
        raise Refused, "#{name}: installed helper is not executable: #{relative_path}" unless executable.executable?

        executable.to_s
      end

      def self.preflight!(formula)
        # Unlink visits bin before share/info. Resolve the optional helper
        # before that traversal can leave commands unavailable on failure.
        Utils::Path.send(:install_info_executable)
        return if formula.opt_prefix.exist? && !formula.linked?

        siblings(formula).each do |sibling|
          next unless sibling.linked? && (formula.keg_only? || sibling.keg_only?)

          raise Refused, "#{formula.name}: linking would unlink unplanned sibling #{sibling.full_name}"
        end
      end
    end

    module FormulaInspection
      def link_overwrite_formulae
        InstalledState.siblings(self)
      end

      def link_overwrite?(path)
        # A recipe's overwrite declaration cannot authorize displacing another
        # package or an unmanaged file. Normal native conflict errors remain.
        return false unless path.symlink? && Keg.for(path).name == name

        super
      rescue NotAKegError, Errno::ENOENT
        false
      end
    end

    module InfoHelper
      private

      def install_info_executable
        return "/usr/bin/install-info" if File.executable?("/usr/bin/install-info")

        InstalledState.executable("texinfo", "bin/install-info")
      end
    end
  end
end
