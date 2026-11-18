# frozen_string_literal: true

require "json"
require "tempfile"
require_relative "inventory"
require_relative "errors"

module BrewCooldown
  module Executor
    class Journal
      LEGACY_JOURNAL = "This journal predates command-link baselines; pre-upgrade command links were not recorded."

      attr_reader :path, :data

      def initialize(directory)
        @directory = Pathname(directory)
        @directory.mkpath
        @path = @directory/"active.json"
        @data = nil
      end

      def with_lock
        File.open(@directory/"run.lock", File::RDWR | File::CREAT, 0o600) do |lock|
          unless lock.flock(File::LOCK_EX | File::LOCK_NB)
            raise Refused, "another brew-cooldown invocation owns #{@directory}"
          end

          yield
        end
      end

      def load
        return unless path.file?

        parsed = JSON.parse(path.read)
        unless parsed.is_a?(Hash) && [1, 2].include?(parsed["schema"])
          raise Refused, "unsupported execution journal schema"
        end
        unless parsed.fetch("prefix") == HOMEBREW_PREFIX.realpath.to_s
          raise Refused,
                "journal belongs to a different Homebrew prefix"
        end
        unless parsed.fetch("inventory").is_a?(Hash) && parsed.fetch("inventory").all? do |key, value|
          key.is_a?(String) && value.is_a?(String)
        end &&
               parsed.fetch("operations").is_a?(Array)
          raise Refused, "invalid execution journal contents"
        end

        parsed.fetch("operations").each do |entry|
          next if entry.is_a?(Hash) && entry.fetch("name").is_a?(String) &&
                  entry.fetch("name").match?(/\A[a-z0-9][a-z0-9+@._-]*\z/) &&
                  entry.fetch("version").is_a?(String) && !entry.fetch("version").empty? &&
                  (entry["previous_keg"].nil? || entry["previous_keg"].is_a?(String)) &&
                  %w[formula cask].include?(entry.fetch("kind", "formula")) &&
                  %w[pending started completed failed].include?(entry.fetch("status")) &&
                  [true, false].include?(entry.fetch("keg_only"))

          raise Refused, "invalid journal operation"
        end
        # Every operation's shape is checked before any identity is, so a
        # journal with both kinds of damage is refused for its shape.
        parsed.fetch("operations").each do |entry| # rubocop:disable Style/CombinableLoops
          full_name = entry["full_name"]
          next if full_name.nil?

          next if full_name.is_a?(String) &&
                  full_name.match?(%r{\A(?:[a-z0-9_-]+/[a-z0-9_-]+/)?[a-z0-9][a-z0-9+@._-]*\z}) &&
                  full_name.split("/").last == entry.fetch("name") && !full_name.include?("..")

          raise Refused, "invalid journal canonical package identity"
        end
        keys = parsed.fetch("operations").map { |entry| [entry.fetch("kind", "formula"), entry.fetch("name")] }
        raise Refused, "duplicate journal operation identity" unless keys.uniq.length == keys.length

        @data = parsed

        data
      end

      def start(operations, inventory)
        raise Refused, "unfinished execution journal: #{path}" if path.exist?

        @data = { "schema" => 2, "prefix" => HOMEBREW_PREFIX.realpath.to_s,
                  "inventory" => inventory, "operations" => operations }
        persist
      end

      def record(name, status, kind: "formula", inventory: nil, error: nil)
        operation = data.fetch("operations").find do |entry|
          entry.fetch("name") == name && entry.fetch("kind", "formula") == kind
        end
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

      def report(observed: Inventory.capture)
        load unless data
        # A legacy baseline cannot identify command links lost before its
        # journal was written. Do not present current links as that baseline.
        legacy = data.fetch("schema") == 1
        compared = legacy ? observed.reject { |path, _| Inventory.command_link?(path) } : observed
        {
          "status" => "needs_reconciliation",
          "journal" => path.to_s,
          "drift" => Inventory.differences(data.fetch("inventory"), compared),
          "unverified" => legacy ? [LEGACY_JOURNAL] : [],
          "operations" => data.fetch("operations").map do |entry|
            entry.merge("status" => entry.fetch("status") == "started" ? "unconfirmed" : entry.fetch("status"),
                        "recovery" => Recovery.commands(entry.fetch("full_name", entry.fetch("name")),
                                                        kind: entry.fetch("kind", "formula"),
                                                        previous_keg: entry["previous_keg"],
                                                        keg_only: entry.fetch("keg_only")))
          end
        }
      end

      def safe_report
        report
      rescue StandardError => e
        { "status" => "journal_error", "journal" => path.to_s,
          "journal_error" => "#{e.class}: #{e.message}",
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
