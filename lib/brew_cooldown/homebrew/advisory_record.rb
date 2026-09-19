# frozen_string_literal: true

require "vulns/vulnerability"
require "date"

module BrewCooldown
  module HomebrewAdapter
    AdvisoryResult = Data.define(:id, :installed_state, :candidate_state, :fixed, :reason)

    # Homebrew's evaluator tolerates partial inputs. A negative assessment used
    # for expedited adoption needs complete, comparable evidence instead.
    class AdvisoryRecord
      class Invalid < StandardError; end

      def initialize(record, name:)
        @record = record
        @name = name
      end

      def assess(installed_version:, candidate_version:, installed_patches: [], candidate_patches: [])
        validate!
        return result(:withdrawn, :withdrawn, false, "Advisory withdrawn") if @record["withdrawn"]

        before, before_reason = installed_version ? state(installed_version, installed_patches) : [nil, nil]
        after, after_reason = state(candidate_version, candidate_patches)
        fixed = before == :affected && after == :fixed
        reasons = [before_reason, after_reason].compact.uniq
        result(before, after, fixed, reasons.empty? ? nil : reasons.join("; "))
      rescue Invalid, Homebrew::Vulns::Vulnerability::Uncomparable => error
        result(:unknown, :unknown, false, error.message)
      end

      private

      def result(before, after, fixed, reason)
        id = @record.is_a?(Hash) && @record["id"].is_a?(String) ? @record["id"] : nil
        AdvisoryResult.new(id:, installed_state: before, candidate_state: after, fixed:, reason:)
      end

      def text?(value)
        value.is_a?(String) && !value.empty? && value == value.strip
      end

      def strings!(values, field)
        raise Invalid, "#{field} must be a list of nonempty strings" unless
          values.is_a?(Array) && values.all? { |value| text?(value) }
      end

      def validate!
        raise Invalid, "Advisory must be an object with an identifier" unless
          @record.is_a?(Hash) && text?(@record["id"])
        schema = @record.fetch("schema_version", "1.0.0")
        raise Invalid, "Unsupported advisory schema #{schema.inspect}" unless
          schema.is_a?(String) && schema.match?(/\A1\.[0-9]+\.[0-9]+\z/)
        if @record.key?("withdrawn")
          raise Invalid, "Invalid withdrawal marker" unless text?(@record["withdrawn"])
          begin
            DateTime.rfc3339(@record.fetch("withdrawn"))
          rescue Date::Error => error
            raise Invalid, "Invalid withdrawal date: #{error.message}"
          end
          return
        end

        %w[aliases upstream].each { |field| strings!(@record.fetch(field, []), field) }
        affected = @record["affected"]
        raise Invalid, "Advisory affected entries must be objects" unless
          affected.is_a?(Array) && affected.all? { |entry| entry.is_a?(Hash) && entry["package"].is_a?(Hash) }

        @entries = affected.select do |entry|
          entry["package"]["ecosystem"] == "Homebrew" && entry["package"]["name"] == @name
        end
        raise Invalid, "No exact Homebrew package match" if @entries.empty?

        @validation_errors = []
        @entries = @entries.map do |entry|
          strings!(entry.fetch("versions", []), "affected versions")
          ranges = entry.fetch("ranges", [])
          raise Invalid, "Affected ranges must be a list" unless ranges.is_a?(Array)
          raise Invalid, "No comparable affected versions or ranges" if ranges.empty? && entry.fetch("versions", []).empty?
          ecosystem = entry.fetch("ecosystem_specific", {})
          raise Invalid, "Invalid ecosystem metadata" unless ecosystem.is_a?(Hash)
          raise Invalid, "Unknown Homebrew fix method" unless [nil, "bump", "patch"].include?(ecosystem["fix"])

          valid_ranges = ranges.select do |range|
            begin
              validate_range!(range)
              true
            rescue Invalid, Homebrew::Vulns::Vulnerability::Uncomparable => error
              @validation_errors << error.message
              false
            end
          end
          entry.merge("ranges" => valid_ranges)
        end
        # Ancillary display metadata must not broaden the evidence surface used
        # for eligibility or make a malformed CVSS field abort the whole feed.
        @vulnerability = Homebrew::Vulns::Vulnerability.new("id" => @record.fetch("id"), "affected" => @entries)
      end

      def validate_range!(range)
        raise Invalid, "Unsupported version range" unless
          range.is_a?(Hash) && %w[ECOSYSTEM SEMVER].include?(range["type"])
        events = range["events"]
        raise Invalid, "Version range has no events" unless events.is_a?(Array) && !events.empty?

        open = false
        previous = nil
        previous_kind = nil
        comparator = Homebrew::Vulns::Vulnerability.new("id" => @record.fetch("id"))
                                               .comparator_for(range.fetch("type"))
        events.each do |event|
          raise Invalid, "Invalid range event" unless event.is_a?(Hash) && event.size == 1
          kind, value = event.first
          raise Invalid, "Unknown or invalid range boundary" unless
            %w[introduced fixed last_affected limit].include?(kind) && text?(value)
          if kind == "introduced"
            raise Invalid, "Overlapping or repeated introduction" if open
            open = true
          else
            raise Invalid, "Terminal boundary without introduction" unless open
            open = false
          end
          if value == "*"
            raise Invalid, "Unbounded limit must end the range" unless kind == "limit" && event.equal?(events.last)
          elsif previous && previous != "0"
            comparison = comparator.call(value, previous)
            inclusive = kind == "last_affected" && previous_kind == "introduced"
            raise Invalid, "Unordered version boundaries" if comparison.negative? || (comparison.zero? && !inclusive)
          elsif value == "0" && !(kind == "introduced" && previous.nil?)
            raise Invalid, "Zero introduction must start the range"
          end
          previous = value
          previous_kind = kind
        end
      end

      def state(version, patches)
        errors = @validation_errors.dup
        comparable = @entries.map do |entry|
          ranges = entry.fetch("ranges").select do |range|
            begin
              comparator = @vulnerability.comparator_for(range.fetch("type"))
              range.fetch("events").each do |event|
                boundary = event.values.first
                next if boundary == "0" || boundary == "*"

                comparator.call(version, boundary)
              end
              true
            rescue Homebrew::Vulns::Vulnerability::Uncomparable => error
              errors << error.message
              false
            end
          end
          entry.merge("ranges" => ranges)
        end
        vulnerability = Homebrew::Vulns::Vulnerability.new("id" => @record.fetch("id"), "affected" => comparable)
        status = vulnerability.range_status("Homebrew", @name, version)
        return [:affected, errors.empty? ? nil : errors.uniq.join("; ")] if status&.affected?
        return [:unknown, errors.uniq.join("; ")] unless errors.empty?
        return [:unknown, "No comparable version evidence"] unless status
        if vulnerability.prerelease_boundary?("Homebrew", @name, version)
          return [:unknown, "Ambiguous semantic prerelease boundary"]
        end

        if comparable.any? { |entry| entry.dig("ecosystem_specific", "fix") == "patch" } && status.fixed?
          return [:unknown, "Selected recipe has no matching patch evidence"] unless patch_confirmed?(patches)
        end
        return [:fixed, nil] if status.fixed? && status.fixed_in

        [:not_affected, nil]
      end

      def patch_confirmed?(patches)
        direct = [@record.fetch("id"), *@record.fetch("aliases", [])]
        upstream = @record.fetch("upstream", [])
        (direct & patches).any? || (!upstream.empty? && (upstream - patches).empty?)
      end
    end
  end
end
