# frozen_string_literal: true

require_relative "candidate_evidence"
require_relative "cask_history"
require_relative "cask_evidence"
require_relative "current_formula"
require_relative "advisories"
require_relative "registry"
require_relative "build_order"
require_relative "../observations"

module BrewCooldown
  module HomebrewAdapter
    class Revalidation
      def initialize(config:, inventory:, prepared:, state_directory:, log:, clock:)
        @config, @inventory, @prepared, @directory, @log, @clock = config, inventory, prepared, state_directory, log, clock
      end

      def check!(selected, verify_payload: true)
        @config.verify_current!
        observations = Observations.new(@directory, prefix: HOMEBREW_PREFIX)
        observations.remember_clock(now: @clock.call)
        advisory = Advisories.refresh(now: @clock.call, log: @log)
        registry = Registry.new(transport: RegistryTransport.new(log: @log))
        selected.each do |package, option|
          next if option.retained

          candidate = @prepared.fetch(option.release.identity)
          release = if package.kind == :cask
            cask_release(package, candidate, verify_payload:)
          else
            formula_release(package, candidate, registry, verify_payload:)
          end
          unless release.identity == option.release.identity
            raise Executor::Refused, "#{package.name}: selected artifact changed upstream; run again to select from current history"
          end
          installed = @inventory.records[package]
          candidate_patches = package.kind == :formula ? Advisories.patch_identifiers(candidate.formula) : []
          installed_patches = if package.kind == :formula && installed&.retained
            Advisories.patch_identifiers(installed.retained.formula)
          else
            []
          end
          assessment = advisory.assess(release:, installed: installed&.installed, candidate_patches:, installed_patches:)
          now = @clock.call
          observations.remember_clock(now:)
          first_seen = observations.first_seen(release, now:) unless release.published_at
          decision = Policy.new(compare_builds: BuildOrder, delays: @config.delays(package))
                           .evaluate(release:, installed: installed&.installed, now:, security: assessment.evidence, first_seen:)
          raise Executor::Refused, "#{package.name}: #{decision.reason}" unless decision.eligible?

          @log.call(operation: "revalidate_candidate", package: package.name, identity: release.identity, status: decision.status)
        end
      end

      private

      def formula_release(package, candidate, registry, verify_payload:)
        current = CurrentFormula.fetch(package.name, log: @log)
        tag = candidate.identity.fetch("version")
        tag += "-#{candidate.rebuild}" if candidate.rebuild.positive?
        metadata = registry.resolve(package.name, tag, platform: candidate.tag)
        release = CandidateEvidence.release(package, candidate, metadata)
        CurrentFormula.verify_candidate!(current, release.build)
        # Reverify the cached payload before native pouring. A mutable tag or
        # a cache replacement cannot inherit the plan's artifact authority.
        if verify_payload
          candidate.bottle.fetch
          Homebrew::Attestation.check_core_attestation(candidate.bottle)
          candidate.bottle.with_verified_snapshot(candidate.bottle.cached_download) { |_snapshot| nil }
        end
        release
      end

      def cask_release(package, candidate, verify_payload:)
        current = CurrentCask.fetch(package.name, log: @log)
        CurrentCask.verify_candidate!(current, candidate.cask.version.to_s)
        history = CaskHistory.new(current:, log: @log)
        entry = history.entries.find { |row| row.commit == candidate.record.fetch("commit") }
        raise Executor::Refused, "#{package.name}: selected recipe is no longer reachable in current Homebrew history" unless entry

        source = history.source_record(entry)
        unless source.all? { |key, value| candidate.record[key] == value }
          raise Executor::Refused, "#{package.name}: selected cask source changed upstream"
        end
        candidate.download.fetch if verify_payload
        candidate.verify!
        CaskEvidence.release(package, candidate, published_at: entry.published_at)
      end
    end
  end
end
