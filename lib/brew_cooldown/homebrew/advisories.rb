# frozen_string_literal: true

require "vulns/advisory_database"
require "pkg_version"
require_relative "../policy"
require_relative "advisory_record"

module BrewCooldown
  module HomebrewAdapter
    # Return the actual refreshed snapshot, avoiding a second read that could
    # observe a different process's cache replacement and inherit its timestamp.
    class AdvisoryFeed < Homebrew::Vulns::AdvisoryDatabase
      attr_reader :records

      def initialize(data)
        super
        @records = data.fetch("advisories")
      end
    end

    SecurityAssessment = Data.define(:evidence, :coverage, :advisories, :diagnostics, :source)

    class Advisories
      SOURCE = Homebrew::Vulns::AdvisoryDatabase::DATA_URL

      def self.refresh(now:, log:, cache: HOMEBREW_CACHE/"vulns", fetch: AdvisoryFeed.method(:refresh))
        path = Pathname(cache)/AdvisoryFeed.cache_filename
        log.call(operation: "refresh_advisories", source: SOURCE)
        begin
          feed = fetch.call(path)
        rescue ErrorDuringExecution, Homebrew::Vulns::CachedFeed::Error, SystemCallError => error
          diagnostic = { operation: "refresh_advisories", error: error.message, error_class: error.class.name,
                         backtrace: error.backtrace }
          log.call(**diagnostic)
          return cached(path, diagnostic:, log:)
        end
        log.call(operation: "refresh_advisories", result: "completed")
        new(records: feed.records, validated_at: now)
      end

      def self.cached(path, diagnostic:, log:)
        return new(records: {}, validated_at: nil, diagnostics: [diagnostic]) unless path.exist?

        begin
          feed = AdvisoryFeed.from_file(path)
        rescue Homebrew::Vulns::CachedFeed::Error, SystemCallError => error
          failure = { operation: "read_cached_advisories", error: error.message, error_class: error.class.name,
                      backtrace: error.backtrace }
          log.call(**failure)
          return new(records: {}, validated_at: nil, diagnostics: [diagnostic, failure])
        end
        new(records: feed.records, validated_at: nil, diagnostics: [diagnostic])
      end
      private_class_method :cached

      def initialize(records:, validated_at:, diagnostics: [])
        @records = records
        @validated_at = validated_at
        @diagnostics = diagnostics
      end

      def self.patch_identifiers(formula)
        formula.patchlist.flat_map { |patch| patch.respond_to?(:resolves) ? patch.resolves : [] }.uniq
      end

      def assess(release:, installed:, candidate_patches: [], installed_patches: [])
        package = release.package
        raise ArgumentError, "Installed and candidate identities differ" if installed && installed.package != package

        supported = package.kind == :formula && package.tap == "homebrew/core"
        records = supported ? @records.fetch(package.name, []) : []
        records = [records] unless records.is_a?(Array)
        results = records.map do |record|
          AdvisoryRecord.new(record, name: package.name).assess(
            installed_version: installed && pkg_version(installed.build), candidate_version: pkg_version(release.build),
            candidate_patches:, installed_patches:,
          )
        end.reject { |entry| entry.candidate_state == :withdrawn }
        before = affected(results.map(&:installed_state))
        after = affected(results.map(&:candidate_state))
        evidence = SecurityEvidence.new(installed_affected: before, candidate_affected: after,
                                        fixed_advisories: results.select(&:fixed).map(&:id).uniq.freeze,
                                        validated_at: @validated_at)
        coverage = if !supported
          :unsupported_package
        elsif results.empty?
          :no_records
        elsif results.any? { |entry| entry.reason || entry.candidate_state == :unknown }
          :incomplete
        else
          :assessed_records
        end
        SecurityAssessment.new(evidence:, coverage:, advisories: results.freeze,
                               diagnostics: @diagnostics.freeze, source: SOURCE)
      end

      private

      def pkg_version(build)
        PkgVersion.new(Version.new(build.version), build.revision).to_s
      end

      def affected(states)
        return true if states.include?(:affected)
        return nil if states.empty? || states.any? { |state| state.nil? || state == :unknown }

        false
      end
    end
  end
end
