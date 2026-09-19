# frozen_string_literal: true

require "digest"
require "shellwords"
require_relative "journals"

module BrewCooldown
  class Recovery
    def initialize(state_directory:, log:)
      @journals = Journals.new(state_directory)
      @directory, @log = state_directory, log
    end

    def call(accept_current: nil)
      @journals.with_lock do
        pending = @journals.pending
        if pending.empty?
          raise Executor::Refused, "No unfinished journal matches this acknowledgment" if accept_current

          return { schema: 1, command: "recover", status: "idle", message: "No unfinished upgrade journal." }
        end
        with_journal_locks(pending) do
          pending.each do |journal|
            @log.call(operation: "read_recovery_journal", path: journal.path.to_s)
            journal.load
          end
          inventory = Executor::Inventory.capture
          evidence = pending.map { |journal| [journal.path.to_s, journal.path.read] }
          # The acknowledgment covers this whole set, including each journal's
          # identity, so replacement or newly unfinished work needs inspection.
          digest = Digest::SHA256.hexdigest(JSON.generate([evidence, inventory]))
          if accept_current
            raise Executor::Refused, "Journal or inventory changed; run recover again before accepting current state" unless
              accept_current == digest

            accepted = pending.map { |journal| journal.accept_current(expected_inventory: inventory) }
            @log.call(operation: "accept_recovery", status: "accepted_current")
            return { schema: 1, command: "recover", status: "accepted_current",
                     operations: accepted.flat_map { |entry| entry.fetch("operations") },
                     message: "Current inventory accepted; the next upgrade must compute a fresh plan. Hook completion remains unverified." }
          end
          reports = pending.map { |journal| journal.report(observed: inventory) }
          launcher = File.expand_path("../../bin/brew-cooldown", __dir__)
          @log.call(operation: "inspect_recovery", status: "needs_reconciliation")
          { schema: 1, command: "recover", status: "needs_reconciliation",
            journals: reports.map { |entry| entry.fetch("journal") },
            drift: reports.flat_map { |entry| entry.fetch("drift") }.uniq,
            operations: reports.flat_map { |entry| entry.fetch("operations") },
            accept_current: {
              "digest" => digest,
              "purpose" => "Acknowledge the reviewed inventory and clear these journals; hook completion remains unverified",
              "command" => Shellwords.join([launcher, "recover", "--accept-current", digest]),
            } }
        end
      end
    rescue StandardError => error
      @log.call(operation: "recover", error: error.message, error_class: error.class.name, backtrace: error.backtrace)
      { schema: 1, command: "recover", status: "error", journal: @directory.to_s,
        error: error.message, message: "Preserve the journals and inspect installed state before retrying." }
    end

    private

    def with_journal_locks(journals, &block)
      return yield if journals.empty?

      journals.first.with_lock { with_journal_locks(journals.drop(1), &block) }
    end
  end
end
