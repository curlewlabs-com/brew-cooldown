# frozen_string_literal: true

require "digest"
require "shellwords"
require_relative "../../prototype/journal"

module BrewCooldown
  class Recovery
    def initialize(state_directory:, log:)
      @journal = Prototype::Journal.new(state_directory)
      @log = log
    end

    def call(accept_current: nil)
      @log.call(operation: "read_recovery_journal", path: @journal.path.to_s)
      @journal.with_lock do
        unless @journal.load
          raise Prototype::Refused, "No unfinished journal matches this acknowledgment" if accept_current

          return { schema: 1, command: "recover", status: "idle", message: "No unfinished upgrade journal." }
        end
        inventory = Prototype::Inventory.capture
        # Acknowledgment authorizes this evidence only, never the next journal
        # written at the same path or a subsequently changed installation.
        digest = Digest::SHA256.hexdigest(JSON.generate([@journal.path.read, inventory]))
        if accept_current
          raise Prototype::Refused, "Journal or inventory changed; run recover again before accepting current state" unless
            accept_current == digest

          result = @journal.accept_current(expected_inventory: inventory)
          @log.call(operation: "accept_recovery", status: result.fetch("status"))
        else
          result = @journal.report(observed: inventory)
          launcher = File.expand_path("../../bin/brew-cooldown", __dir__)
          result["accept_current"] = {
            "digest" => digest,
            "purpose" => "Acknowledge the reviewed inventory and clear this journal; hook completion remains unverified",
            "command" => Shellwords.join([launcher, "recover", "--accept-current", digest]),
          }
          @log.call(operation: "inspect_recovery", status: result.fetch("status"))
        end
        result.transform_keys(&:to_sym).merge(schema: 1, command: "recover")
      end
    rescue StandardError => error
      @log.call(operation: "recover", error: error.message, error_class: error.class.name, backtrace: error.backtrace)
      { schema: 1, command: "recover", status: "error", journal: @journal.path.to_s,
        error: error.message, message: "Preserve the journal and inspect installed state before retrying." }
    end
  end
end
