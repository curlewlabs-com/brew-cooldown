# frozen_string_literal: true

require "open3"
require_relative "../validated_homebrew"
require_relative "formula_operation"
require_relative "cask_operation"
require_relative "journal"

module BrewCooldown
  module Executor
    class Execution
      attr_reader :map, :journal

      def initialize(map, state_directory:, casks: [])
        @map = map
        @operations = map.candidates.values.select(&:install?).map { |candidate| FormulaOperation.new(candidate, map:) } + casks
        @journal = Journal.new(state_directory)
      end

      def self.check_homebrew!
        raise Refused, "execution needs Apple Silicon macOS at /opt/homebrew" unless
          OS.mac? && Hardware::CPU.arm? && HOMEBREW_PREFIX.to_s == "/opt/homebrew"

        head, status = Open3.capture2("git", "-C", HOMEBREW_REPOSITORY.to_s, "rev-parse", "HEAD")
        raise Refused, "Homebrew checkout identity unavailable" unless status.success?
        unless head.strip == VALIDATED_HOMEBREW_COMMIT
          raise Refused, "Homebrew checkout #{head.strip} is not the commit the installer adapter was qualified on " \
                         "(#{VALIDATED_HOMEBREW_COMMIT}); plan and explain still work, upgrade does not"
        end

        changes, status = Open3.capture2("git", "-C", HOMEBREW_REPOSITORY.to_s,
                                       "status", "--porcelain", "--untracked-files=no")
        raise Refused, "Homebrew checkout changed" unless status.success? && changes.empty?
      end

      def apply(expected_inventory:, before_install: nil, &progress)
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
                       "recovery" => recovery_commands }
            end
            raise Refused, "native installer already holds locks" unless FormulaInstaller.locked.empty?

            # Native finish releases locks only when its own installer acquired
            # them. Our component retains ownership until this outer ensure.
            FormulaInstaller.locked.concat(map.candidates.values.map(&:formula))
            owns_installer_locks = true
            execute(actual, progress:, before_install:)
          ensure
            FormulaInstaller.locked.clear if owns_installer_locks
            locks.reverse_each(&:unlock)
          end
        end
      rescue StandardError => error
        details = journal.path.file? ? journal.safe_report : { "status" => "error" }
        details.merge("error" => "#{error.class}: #{error.message}",
                      "recovery" => recovery_commands)
      end

      private

      def recovery_commands
        formulae = map.candidates.values.to_h do |candidate|
          name = candidate.formula.full_name
          ["formula/#{name}", Recovery.commands(name)]
        end
        formulae.merge(@operations.to_h do |operation|
          ["#{operation.kind}/#{operation.name}", Recovery.commands(operation.name, kind: operation.kind)]
        end)
      end

      def ordered_operations
        operations = @operations.to_h { |operation| [operation.key, operation] }
        result = []
        visiting = Set.new
        visited = Set.new
        visit = lambda do |key|
          # Retained dependencies constrain the plan but are not install steps.
          # Traversing their edges would invent installation cycles.
          return unless operations.key?(key)
          return if visited.include?(key)
          raise Refused, "dependency cycle at #{key.join('/')}" if visiting.include?(key)

          visiting << key
          operation = operations.fetch(key)
          operation.dependencies.each { |dependency| visit.call(dependency) }
          visiting.delete(key)
          visited << key
          result << operation
        end
        operations.each_key { |key| visit.call(key) }
        result
      end

      def execute(inventory, progress:, before_install:)
        operations = ordered_operations
        journal.start(operations.map(&:record), inventory)
        operations.each do |operation|
          name, kind = operation.name, operation.kind
          self.class.check_homebrew!
          current = Inventory.capture
          raise Refused, "inventory changed before #{kind}/#{name}" unless current == inventory
          operation.verify_before!
          before_install&.call(operation.candidate)
          raise Refused, "inventory changed during #{kind}/#{name} revalidation" unless Inventory.capture == inventory

          journal.record(name, "started", kind:)
          progress&.call(name, "started")
          begin
            Homebrew.failed = false
            operation.install
            map.candidates.values.reject(&:install?).each(&:check_linkage!)
            after = Inventory.capture
            unexpected = Inventory.differences(inventory, after).reject { |change| operation.owns_path?(change.fetch("path")) }
            raise Refused, "unplanned inventory change after #{kind}/#{name}: #{unexpected}" unless unexpected.empty?

            inventory = after
            journal.record(name, "completed", kind:, inventory:)
          rescue StandardError => error
            warn JSON.generate("operation" => "install", "kind" => kind, "package" => name,
                               "error" => "#{error.class}: #{error.message}", "backtrace" => error.backtrace)
            journal.record(name, "failed", kind:, error: "#{error.class}: #{error.message}")
            return journal.report
          end
          progress&.call(name, "completed")
        end
        result = { "status" => "completed", "operations" => journal.data.fetch("operations") }
        journal.finish
        result
      end
    end
  end
end
