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

        check_checkout!(HOMEBREW_REPOSITORY.to_s)
      end

      def self.check_checkout!(repository, validated: VALIDATED_HOMEBREW_COMMIT)
        head, status = Open3.capture2("git", "-C", repository, "rev-parse", "HEAD")
        raise Refused, "Homebrew checkout identity unavailable" unless status.success?
        head = head.strip
        raise Refused, unqualified_checkout(repository, head, validated) unless head == validated

        changes, status = Open3.capture2("git", "-C", repository, "status", "--porcelain", "--untracked-files=no")
        raise Refused, "Homebrew checkout changed" unless status.success? && changes.empty?
      end

      # A release awaits qualification, but a checkout between releases never
      # gets it: `brew update` follows Homebrew's main branch while developer
      # mode is on, and any developer command such as `brew ruby` turns that
      # mode on until `brew developer off`
      # (https://docs.brew.sh/Manpage#developer-subcommand). Naming that case
      # spares an operator waiting on a qualification that cannot arrive.
      def self.unqualified_checkout(repository, head, validated)
        refusal = "is not the commit the installer adapter was qualified on (#{validated}); " \
                  "plan and explain still work, upgrade does not"
        return "Homebrew checkout #{head} #{refusal}" unless non_release?(repository, head)

        described, status = Open3.capture2("git", "-C", repository, "describe", "--tags", head)
        identity = status.success? ? "#{head} (#{described.strip})" : head
        # `--force` because without it `brew update` leaves a checkout sitting at
        # main's unchanged tip where it is, whatever HOMEBREW_UPDATE_TO_TAG asks:
        # https://github.com/Homebrew/brew/blob/cdc1ca503231b9a96da64526774915d913c3ec9f/Library/Homebrew/cmd/update.sh#L1041-L1049
        # HOMEBREW_UPDATE_TO_TAG is the repair, not `brew developer off`, which
        # leaves developer mode on while HOMEBREW_DEVELOPER is set:
        # https://github.com/Homebrew/brew/blob/c6069d2a943b71b0a90d91fc1ac93cb9c1634dcc/Library/Homebrew/developer/subcommand/off.rb#L23-L26
        "Homebrew checkout #{identity} is not a Homebrew release and #{refusal}. Homebrew follows its main " \
          "branch while developer mode is on; run `HOMEBREW_UPDATE_TO_TAG=1 brew update --force` to return to " \
          "the latest release, then `brew developer off`, and unset HOMEBREW_DEVELOPER if " \
          "`brew developer state` still reports developer mode"
      end

      def self.non_release?(repository, head)
        tags, status = Open3.capture2("git", "-C", repository, "tag", "--points-at", head)
        # The release-tag shape `brew update` itself selects:
        # https://github.com/Homebrew/brew/blob/cdc1ca503231b9a96da64526774915d913c3ec9f/Library/Homebrew/cmd/update.sh#L263-L266
        status.success? && tags.lines.none? { |tag| tag.strip.match?(/\A\d+\.\d+\.\d+\z/) }
      end

      def apply(expected_inventory:, before_install: nil, &progress)
        journal.with_lock do
          return journal.report if journal.load

          self.class.check_homebrew!
          locks = []
          owns_installer_locks = false
          begin
            map.candidates.values.map { |candidate| candidate.formula.name }.sort.each do |name|
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
            unexpected = Inventory.differences(inventory, after).reject { |change| operation.owns_change?(change) }
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
