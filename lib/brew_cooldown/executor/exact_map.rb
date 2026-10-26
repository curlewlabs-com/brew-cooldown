# frozen_string_literal: true

require_relative "candidate"
require_relative "compatibility"
require_relative "installed_state"
require "install"

module BrewCooldown
  module Executor
    # Unknown lookups fail instead of falling through to the current API.
    # postinstall.rb supplies the separate resolver for native hook workers.
    class ExactMap
      attr_reader :candidates

      def initialize(candidates)
        names = candidates.map { |candidate| candidate.formula.name }
        raise Refused, "selected taps collide in Homebrew's shared formula rack" unless names.uniq == names

        @candidates = candidates.to_h { |candidate| [candidate.formula.full_name, candidate] }.freeze
      end

      def resolve(reference)
        candidate = candidates[reference.to_s.delete_prefix("homebrew/core/")]
        return candidate.formula if candidate

        raise Refused, "unplanned formula lookup: #{reference}"
      end

      def validate(formula)
        candidate = candidates[formula.full_name]
        raise Refused, "formula substitution: #{formula.full_name}" unless candidate&.formula.equal?(formula)
        return unless candidate.install?

        return candidate.verify_shape! if candidate.respond_to?(:release_archive?) && candidate.release_archive?

        raise Refused, "local bottle fallback" if formula.local_bottle_path
        raise Refused, "bottle substitution: #{formula.full_name}" unless formula.bottle.equal?(candidate.bottle)
      end

      def activate
        raise Refused, "map already active" if Executor.active_map

        candidates.each_value do |candidate|
          candidate.runtime_dependencies.each do |dependency|
            selected = resolve(dependency.fetch("full_name"))
            target = candidates.fetch(selected.full_name)
            # Keeping an existing edge changes neither endpoint. Its receipt
            # need not establish compatibility for a replacement we never make.
            next unless candidate.install? || target.install?

            Compatibility.validate!(dependency, target)
            candidate.check_candidate!(target) unless candidate.install?
          end
        end
        Executor.active_map = self
        Formulary.singleton_class.prepend(ResolverGuard)
        Dependency.singleton_class.prepend(BottleDependencyGraph)
        Formula.prepend(FormulaInspection)
        Utils::Path.singleton_class.prepend(InfoHelper)
        FormulaInstaller.prepend(InstallerGuard)
        Keg.prepend(KegGuard)
      end
    end

    class << self
      attr_accessor :active_map, :worker_plan, :executing_name
    end

    module ResolverGuard
      def factory(reference, spec = :stable, alias_path: nil, from: nil,
                  warn: false, force_bottle: false, flags: [], ignore_errors: false)
        unless spec == :stable && alias_path.nil? && [nil, :rack, :keg].include?(from) &&
               !force_bottle && flags.empty? && !ignore_errors
          raise Refused, "unplanned formula loading options: #{reference}"
        end

        Executor.active_map.resolve(reference)
      end
    end

    module BottleDependencyGraph
      def expand(dependent, deps = dependent.deps, **options, &block)
        Executor.active_map.validate(dependent)
        runtime_names = Executor.active_map.candidates.fetch(dependent.full_name)
                                 .runtime_dependencies.map { |dependency| dependency.fetch("full_name") }
        # Homebrew's requirement traversal otherwise loads the source-build
        # toolchain even for bottles. Runtime edges keep their native checks.
        runtime = deps.reject do |dependency|
          (dependency.build? || dependency.test?) && !runtime_names.include?(dependency.name)
        end
        super(dependent, runtime, **options, &block)
      end
    end

    module InstallerGuard
      def initialize(formula, **options)
        Executor.active_map.validate(formula)
        unless Executor.active_map.candidates.fetch(formula.full_name).install?
          raise Refused, "#{formula.full_name}: retained consumer cannot be installed outside the plan"
        end
        super
        Executor.active_map.validate(self.formula)
      end

      def prelude
        validate_candidate
        super
      end

      # Natively, every name in conflicts_with loads today's recipe, installed
      # or not, and only a linked keg makes it a conflict. Read that from the
      # prefix, as native code already does for an untrusted tap it will not
      # load, so a recipe naming a formula outside the plan can still install.
      def check_conflicts
        return if force? || skip_link? || !link_keg

        conflicts = formula.conflicts.select do |conflict|
          name = conflict.name.split("/").last
          next false if name == formula.name

          InstalledState.linked?(conflict.name)
        end
        raise FormulaConflictError.new(formula, conflicts) unless conflicts.empty?
      end

      def install
        validate_candidate
        super
      end

      def pour
        validate_candidate
        super
      end

      def build
        validate_candidate
        candidate = Executor.active_map.candidates.fetch(formula.full_name)
        return super if candidate.respond_to?(:release_archive?) && candidate.release_archive?

        raise Refused, "source build requested: #{formula.full_name}"
      end

      def install_dependency(dependency, dependency_formula = dependency.to_formula)
        if Executor.executing_name
          raise Refused, "#{Executor.executing_name}: dependency #{dependency.name} was not completed before installation"
        end

        super
      end

      def post_install
        raise Refused, "post-install worker has no candidate map" unless Executor.worker_plan

        super
      end

      private

      def auto_link_versioned_keg_only?
        # An upgrade preserves the existing prefix-link choice. Native
        # auto-promotion can inspect and displace unrelated Ruby/Python lines.
        false
      end

      public

      def link_manual_command_warning
        # The native warning traverses today's sibling recipes to propose a
        # linking change. This adapter preserves links instead of proposing it.
        nil
      end

      private

      def validate_candidate
        Executor.active_map.validate(formula)
        candidate = Executor.active_map.candidates.fetch(formula.full_name)
        release_archive = candidate.respond_to?(:release_archive?) && candidate.release_archive?
        if release_archive
          raise Refused, "release archive replaced by bottle: #{formula.full_name}" if pour_bottle?
        else
          raise Refused, "source fallback requested: #{formula.full_name}" unless pour_bottle?
        end
        raise Refused, "dependency checks disabled" if ignore_deps?
        raise Refused, "forced bottle compatibility" if force_bottle?
      end
    end

    module KegGuard
      def unlink(**options)
        authorize_mutation!("unlink")
        super
      end

      def link(**options)
        authorize_mutation!("link")
        super
      end

      def optlink(**options)
        authorize_mutation!("optlink")
        # Native optlink deletes alias destinations even without --overwrite.
        # An installed-state answer cannot authorize taking another rack's opt.
        records = [opt_record, *aliases.map { |entry| opt_record.parent/entry }, *oldname_opt_records]
        records.each do |record|
          next unless record.symlink? || record.exist?
          next if record.symlink? && File.expand_path(record.readlink.to_s, record.dirname).start_with?("#{rack}/")

          raise Refused, "#{name}: optlink would overwrite unrelated path #{record}"
        end
        super
      end

      def uninstall(**options)
        authorize_mutation!("uninstall")
        super
      end

      private

      def authorize_mutation!(operation)
        if Executor.executing_name
          return if name == Executor.executing_name
        else
          candidate = Executor.active_map.candidates.values.find { |entry| entry.formula.name == name }
          return if candidate&.install?
        end

        raise Refused, "#{Executor.executing_name || 'exact map'}: unplanned #{operation} of #{name}"
      end
    end
  end
end
