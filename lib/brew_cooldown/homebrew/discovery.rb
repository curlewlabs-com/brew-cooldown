# frozen_string_literal: true

require_relative "registry"
require_relative "advisories"
require_relative "candidate_evidence"
require_relative "current_formula"
require_relative "cask_history"
require_relative "cask_evidence"
require_relative "installed_inventory"
require_relative "compatibility"
require_relative "build_order"
require_relative "../observations"

module BrewCooldown
  module HomebrewAdapter
    DiscoveryResult = Data.define(:domains, :prepared, :decisions, :errors, :diagnostics)

    class Discovery
      class UnknownInstalledBuild < StandardError; end

      def initialize(inventory:, config:, advisories:, observations:, now:, log:)
        @inventory, @config, @advisories, @observations, @now, @log = inventory, config, advisories, observations, now, log
        @registry = Registry.new(transport: RegistryTransport.new(log:))
        @domains, @prepared, @decisions, @errors, @diagnostics = {}, {}, [], [], []
        inventory.records.each do |package, record|
          release = Release.new(package:, build: record.installed.build, identity: record.identity, verified: true,
                                published_at: nil, publication_source: nil)
          decision = Decision.new(status: :retained, reason: "Keep the active installation", eligible_at: nil,
                                  delay_kind: nil, age_source: nil, fixed_advisories: [])
          @domains[package] = [Option.new(release:, decision:, dependencies: record.dependencies,
                                        compatibility_version: record.compatibility_version, retained: true)]
          @prepared[release.identity] = record.retained if record.retained
        end
      end

      def collect(roots)
        @observations.remember_clock(now: @now)
        pending = roots.dup
        visited = Set.new
        until pending.empty?
          package = pending.shift
          next unless visited.add?(package)

          if package.kind == :cask && package.tap == "homebrew/cask"
            collect_cask(package, pending)
            next
          end
          unless package.kind == :formula && package.tap == "homebrew/core"
            record_error(package, "discover", ArgumentError.new("Exact bottled core execution is unavailable for this package"))
            next
          end
          baseline = @inventory.records[package]&.installed
          next if baseline&.pinned

          begin
            current = CurrentFormula.fetch(package.name, log: @log)
            tags = @registry.tags(package.name)
          rescue StandardError => error
            record_error(package, "discover_history", error)
            next
          end
          tags.sort_by { |tag| Version.new(tag) }.reverse_each do |tag|
            # Homebrew increments the scheme when ordinary version ordering
            # changes. Fresh current metadata bounds the historical schemes;
            # when it changed, inspect old-looking version strings too.
            next unless possible_advance?(tag, baseline, current.fetch("version_scheme"))

            begin
              metadata = @registry.resolve(package.name, tag)
              next unless metadata_advances?(metadata, baseline, current.fetch("version_scheme"))

              candidate = prepare(metadata)
              option = evaluate(package, candidate, metadata, baseline, current)
              @domains[package] ||= []
              @domains[package] << option
              @prepared[option.release.identity] = candidate
              next unless option.decision.eligible?

              option.dependencies.each do |requirement|
                retained = @domains.fetch(requirement.package, []).find(&:retained)
                pending << requirement.package unless retained && Compatibility.call(requirement, retained)
              end
            rescue UnknownInstalledBuild => error
              details = { operation: "inspect_installed_artifact", status: "unknown_installed_build",
                          package: package.to_h, reason: error.message, tag:,
                          recovery: Prototype::Recovery.commands(package.name) }
              @diagnostics << details
              @log.call(**details)
            rescue StandardError => error
              record_error(package, "prepare_candidate", error, tag:)
            end
          end
        end
        DiscoveryResult.new(domains: @domains, prepared: @prepared, decisions: @decisions, errors: @errors, diagnostics: @diagnostics)
      end

      private

      def collect_cask(package, pending)
        baseline = @inventory.records[package]&.installed
        return if baseline&.pinned

        current = CurrentCask.fetch(package.name, log: @log)
        history = CaskHistory.new(current:, log: @log)
        history.entries.each do |entry|
          begin
            candidate = history.candidate(entry)
            version = Version.new(candidate.cask.version.to_s)
            # History is newest first, so everything older was superseded
            # before this installation. A higher version further back is one
            # Homebrew later rolled back, and must not return as a candidate.
            break if baseline && version <= Version.new(baseline.build.version)

            CurrentCask.verify_candidate!(current, version.to_s)

            candidate.prepare
            release = CaskEvidence.release(package, candidate, published_at: entry.published_at)
            first_seen = @observations.first_seen(release, now: @now) unless release.published_at
            assessment = @advisories.assess(release:, installed: baseline)
            decision = Policy.new(compare_builds: BuildOrder, delays: @config.delays(package))
                             .evaluate(release:, installed: baseline, now: @now, security: assessment.evidence, first_seen:)
            dependencies = CaskEvidence.requirements(candidate.cask)
            @domains[package] ||= []
            @domains[package] << Option.new(release:, decision:, dependencies:, compatibility_version: nil, retained: false)
            @prepared[release.identity] = candidate
            @decisions << { package: package.to_h, build: release.build.to_h, identity: release.identity, decision: decision.to_h,
              security: { coverage: assessment.coverage, evidence: assessment.evidence.to_h, advisories: [] } }
            next unless decision.eligible?

            dependencies.each { |requirement| pending << requirement.package unless @domains.fetch(requirement.package, []).any?(&:retained) }
          rescue GitHub::API::RateLimitExceededError, GitHub::API::AuthenticationFailedError, GitHub::API::MissingAuthenticationError
            raise
          rescue StandardError => error
            record_error(package, "prepare_cask_candidate", error, commit: entry.commit)
          end
        end
      rescue StandardError => error
        record_error(package, "discover_cask_history", error)
      end

      def possible_advance?(tag, baseline, current_scheme)
        return true unless baseline && current_scheme == baseline.build.scheme

        # A trailing integer may be an upstream version or an OCI rebuild.
        # Considering both interpretations only adds metadata work; discarding
        # one could hide a real candidate before its index disambiguates it.
        versions = [tag, tag.sub(/-[0-9]+\z/, "")].uniq.map { |value| PkgVersion.parse(value) }
        before = PkgVersion.new(Version.new(baseline.build.version), baseline.build.revision)
        versions.any? { |version| version >= before }
      end

      def metadata_advances?(metadata, baseline, current_scheme)
        return true unless baseline && current_scheme == baseline.build.scheme

        before = PkgVersion.new(Version.new(baseline.build.version), baseline.build.revision)
        comparison = PkgVersion.parse(metadata.pkg_version) <=> before
        if comparison.zero? && baseline.build.rebuild.nil?
          return false if metadata.rebuild.zero?

          raise UnknownInstalledBuild, "#{metadata.name} #{metadata.pkg_version}: this version and revision are already installed; " \
                                       "Homebrew does not record the installed bottle rebuild, so registry rebuild #{metadata.rebuild} " \
                                       "cannot establish an upgrade. No rebuild-only replacement is selected"
        end
        comparison.positive? || (comparison.zero? && metadata.rebuild > baseline.build.rebuild)
      end

      def prepare(metadata)
        candidate = Prototype::Candidate.new("name" => metadata.name, "version" => metadata.pkg_version,
                                              "index_sha256" => metadata.index_sha256, "rebuild" => metadata.rebuild,
                                              "platform" => metadata.platform).prepare(allow_hooks: true)
        unless candidate.bottle.resource.checksum.hexdigest == metadata.bottle_sha256 &&
               candidate.runtime_dependencies == metadata.runtime_dependencies
          raise Prototype::Refused, "Prepared artifact differs from discovered metadata"
        end

        candidate
      end

      def evaluate(package, candidate, metadata, baseline, current)
        formula = candidate.formula
        release = CandidateEvidence.release(package, candidate, metadata)
        CurrentFormula.verify_candidate!(current, release.build)
        first_seen = @observations.first_seen(release, now: @now) unless metadata.published_at
        installed_formula = @inventory.records[package]&.retained&.formula
        assessment = @advisories.assess(release:, installed: baseline,
                                        candidate_patches: Advisories.patch_identifiers(formula),
                                        installed_patches: installed_formula ? Advisories.patch_identifiers(installed_formula) : [])
        policy = Policy.new(compare_builds: BuildOrder, delays: @config.delays(package))
        decision = policy.evaluate(release:, installed: baseline, now: @now, security: assessment.evidence, first_seen:)
        @decisions << { package: package.to_h, build: release.build.to_h, identity: release.identity, decision: decision.to_h,
                        security: { coverage: assessment.coverage, evidence: assessment.evidence.to_h,
                                    advisories: assessment.advisories.map(&:to_h) } }
        Option.new(release:, decision:, dependencies: InstalledInventory.requirements(candidate.runtime_dependencies),
                   compatibility_version: candidate.compatibility_version, retained: false)
      end

      def record_error(package, operation, error, **context)
        details = { operation:, package: package.to_h, error: error.message, error_class: error.class.name,
                    backtrace: error.backtrace, **context }
        @errors << details
        @log.call(**details)
      end
    end
  end
end
