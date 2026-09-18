# frozen_string_literal: true

require "open3"
require_relative "postinstall"
require_relative "journal"

module BrewCooldown
  module Prototype
    class Execution
      HOMEBREW_COMMIT = "edb70f031e4170c780799633a1226ff73e1077f4"

      attr_reader :map, :journal

      def initialize(map, state_directory:)
        @map = map
        @journal = Journal.new(state_directory)
      end

      def self.check_homebrew!
        raise Refused, "execution needs Apple Silicon macOS at /opt/homebrew" unless
          OS.mac? && Hardware::CPU.arm? && HOMEBREW_PREFIX.to_s == "/opt/homebrew"

        head, status = Open3.capture2("git", "-C", HOMEBREW_REPOSITORY.to_s, "rev-parse", "HEAD")
        raise Refused, "Homebrew checkout identity unavailable" unless status.success?
        raise Refused, "Homebrew #{head.strip} has not passed adapter validation" unless head.strip == HOMEBREW_COMMIT

        changes, status = Open3.capture2("git", "-C", HOMEBREW_REPOSITORY.to_s,
                                       "status", "--porcelain", "--untracked-files=no")
        raise Refused, "Homebrew checkout changed" unless status.success? && changes.empty?
      end

      def apply(expected_inventory:, &progress)
        journal.with_lock do
          return journal.report if journal.load

          self.class.check_homebrew!
          locks = []
          owns_installer_locks = false
          begin
            map.candidates.keys.sort.each do |name|
              lock = FormulaLock.new(name)
              lock.lock
              locks << lock
            end
            actual = Inventory.capture
            unless actual == expected_inventory
              return { "status" => "drift", "changes" => Inventory.differences(expected_inventory, actual),
                       "recovery" => map.candidates.keys.to_h { |name| [name, Recovery.commands(name)] } }
            end
            raise Refused, "native installer already holds locks" unless FormulaInstaller.locked.empty?

            # Native finish releases locks only when its own installer acquired
            # them. Our component retains ownership until this outer ensure.
            FormulaInstaller.locked.concat(map.candidates.values.map(&:formula))
            owns_installer_locks = true
            execute(actual, progress:)
          ensure
            FormulaInstaller.locked.clear if owns_installer_locks
            locks.reverse_each(&:unlock)
          end
        end
      rescue StandardError => error
        details = journal.path.file? ? journal.safe_report : { "status" => "error" }
        details.merge("error" => "#{error.class}: #{error.message}",
                      "recovery" => map.candidates.keys.to_h { |name| [name, Recovery.commands(name)] })
      end

      private

      def ordered_candidates
        result = []
        visiting = Set.new
        visited = Set.new
        visit = lambda do |candidate|
          name = candidate.formula.full_name
          return if visited.include?(name)
          raise Refused, "dependency cycle at #{name}" if visiting.include?(name)

          visiting << name
          candidate.runtime_dependencies.each { |dep| visit.call(map.candidates.fetch(dep.fetch("full_name"))) }
          visiting.delete(name)
          visited << name
          result << candidate if candidate.install?
        end
        map.candidates.values.each { |candidate| visit.call(candidate) }
        result
      end

      def execute(inventory, progress:)
        candidates = ordered_candidates
        operations = candidates.map do |candidate|
          formula = candidate.formula
          previous = formula.opt_prefix.realpath.to_s if formula.opt_prefix.exist?
          raise Refused, "#{formula.name} is pinned" if formula.pinned?
          if previous && Keg.new(Pathname(previous)).version >= formula.pkg_version
            raise Refused, "#{formula.name}: selected version does not advance the active installation"
          end
          { "name" => formula.name, "version" => formula.pkg_version.to_s, "previous_keg" => previous,
            "candidate" => candidate.identity, "keg_only" => formula.keg_only?, "status" => "pending" }
        end
        journal.start(operations, inventory)
        candidates.each do |candidate|
          formula = candidate.formula
          self.class.check_homebrew!
          current = Inventory.capture
          raise Refused, "inventory changed before #{formula.name}" unless current == inventory
          raise Refused, "#{formula.name} became pinned" if formula.pinned?

          journal.record(formula.name, "started")
          progress&.call(formula.name, "started")
          begin
            Homebrew.failed = false
            Postinstall.with_map(map) do
              installer = FormulaInstaller.new(formula, installed_on_request: true)
              installer.prelude
              installer.fetch
              Homebrew::Install.install_formula(installer, upgrade: formula.opt_prefix.exist?)
            end
            raise Refused, "Homebrew reported failure for #{formula.name}" if Homebrew.failed?
            expected = HOMEBREW_CELLAR/formula.name/formula.pkg_version.to_s
            raise Refused, "#{formula.name}: selected keg is not active" unless formula.opt_prefix.realpath == expected
            raise Refused, "#{formula.name}: installation receipt missing" unless (expected/"INSTALL_RECEIPT.json").file?
            Retained.new(Keg.new(expected)).check_linkage!
            map.candidates.values.reject(&:install?).each(&:check_linkage!)

            after = Inventory.capture
            unexpected = Inventory.differences(inventory, after).reject do |change|
              path = change.fetch("path")
              names = [formula.name, *formula.aliases, *formula.oldnames]
              path.start_with?("#{formula.rack}/") || names.any? do |name|
                [HOMEBREW_PREFIX/"opt"/name, HOMEBREW_LINKED_KEGS/name].any? { |allowed| allowed.to_s == path }
              end
            end
            raise Refused, "unplanned inventory change after #{formula.name}: #{unexpected}" unless unexpected.empty?

            inventory = after
            journal.record(formula.name, "completed", inventory:)
          rescue StandardError => error
            journal.record(formula.name, "failed", error: "#{error.class}: #{error.message}")
            return journal.report
          end
          progress&.call(formula.name, "completed")
        end
        result = { "status" => "completed", "operations" => journal.data.fetch("operations") }
        journal.finish
        result
      end
    end
  end
end
