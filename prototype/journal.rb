# frozen_string_literal: true

require "json"
require "tempfile"
require_relative "inventory"

module BrewCooldown
  module Prototype
    class Journal
      attr_reader :path, :data

      def initialize(directory)
        @directory = Pathname(directory)
        @directory.mkpath
        @path = @directory/"active.json"
        @data = nil
      end

      def with_lock
        File.open(@directory/"run.lock", File::RDWR | File::CREAT, 0600) do |lock|
          raise Refused, "another brew-cooldown invocation owns #{@directory}" unless lock.flock(File::LOCK_EX | File::LOCK_NB)

          yield
        end
      end

      def load
        return unless path.file?

        parsed = JSON.parse(path.read)
        raise Refused, "unsupported execution journal schema" unless parsed.is_a?(Hash) && parsed["schema"] == 1
        raise Refused, "journal belongs to a different Homebrew prefix" unless parsed.fetch("prefix") == HOMEBREW_PREFIX.realpath.to_s
        unless parsed.fetch("inventory").is_a?(Hash) && parsed.fetch("operations").is_a?(Array)
          raise Refused, "invalid execution journal contents"
        end
        parsed.fetch("operations").each do |entry|
          unless entry.is_a?(Hash) && entry.fetch("name").is_a?(String) &&
                 %w[pending started completed failed].include?(entry.fetch("status")) &&
                 [true, false].include?(entry.fetch("keg_only"))
            raise Refused, "invalid journal operation"
          end
        end
        @data = parsed

        data
      end

      def start(operations, inventory)
        raise Refused, "unfinished execution journal: #{path}" if path.exist?

        @data = { "schema" => 1, "prefix" => HOMEBREW_PREFIX.realpath.to_s,
                  "inventory" => inventory, "operations" => operations }
        persist
      end

      def record(name, status, inventory: nil, error: nil)
        operation = data.fetch("operations").find { |entry| entry.fetch("name") == name }
        raise Refused, "unplanned journal operation #{name}" unless operation

        operation["status"] = status
        operation["error"] = error if error
        data["inventory"] = inventory if inventory
        persist
      end

      def finish
        path.unlink
        sync_directory
      end

      def accept_current(expected_inventory:)
        observed = Inventory.capture
        raise Refused, "inventory changed while reviewing recovery" unless observed == expected_inventory

        result = { "status" => "accepted_current", "operations" => data.fetch("operations"),
                   "message" => "Current inventory accepted; the next upgrade must compute a fresh plan." }
        finish
        result
      end

      def report
        load unless data
        observed = Inventory.capture
        {
          "status" => "needs_reconciliation",
          "journal" => path.to_s,
          "drift" => Inventory.differences(data.fetch("inventory"), observed),
          "operations" => data.fetch("operations").map do |entry|
            entry.merge("status" => entry.fetch("status") == "started" ? "unconfirmed" : entry.fetch("status"),
                        "recovery" => Recovery.commands(entry.fetch("name"),
                                                        previous_keg: entry["previous_keg"],
                                                        keg_only: entry.fetch("keg_only")))
          end
        }
      end

      def safe_report
        report
      rescue StandardError => error
        { "status" => "journal_error", "journal" => path.to_s,
          "journal_error" => "#{error.class}: #{error.message}",
          "message" => "Preserve this journal for inspection; package completion could not be determined." }
      end

      private

      def persist
        Tempfile.create(["journal-", ".json"], @directory) do |file|
          file.write(JSON.generate(data))
          file.flush
          file.fsync
          File.rename(file.path, path)
          sync_directory
        end
      end

      def sync_directory
        File.open(@directory, File::RDONLY, &:fsync)
      end
    end
  end
end
