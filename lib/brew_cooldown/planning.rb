# frozen_string_literal: true

require_relative "config"
require_relative "homebrew/scope"
require_relative "homebrew/discovery"
require_relative "homebrew/advisories"

module BrewCooldown
  class Planning
    attr_reader :inventory, :discovery, :resolutions
    def initialize(config:, scope:, now:, log:, state_directory:)
      @config, @scope, @now, @log, @state_directory = config, scope, now, log, state_directory
    end

    def call
      @inventory = HomebrewAdapter::InstalledInventory.capture(log: @log)
      entries = HomebrewAdapter::Scope.read(@scope, installed: inventory.records.keys)
      scope_results = entries.map { |entry| resolve_entry(entry, inventory) }
      roots = scope_results.filter_map { |entry| entry[:package] if %i[selected pinned].include?(entry[:status]) }.uniq
      errors = inventory.errors.dup
      errors.concat(scope_results.select { |entry| %i[missing unsupported_executor ambiguous].include?(entry[:status]) })
      advisory = HomebrewAdapter::Advisories.refresh(now: @now, log: @log)
      observations = Observations.new(@state_directory, prefix: HOMEBREW_PREFIX)
      @discovery = HomebrewAdapter::Discovery.new(inventory:, config: @config, advisories: advisory,
                                               observations:, now: @now, log: @log).collect(roots)
      errors.concat(discovery.errors)
      planner = Planner.new(compare_builds: HomebrewAdapter::BuildOrder, compatible: HomebrewAdapter::Compatibility,
                            max_assignments: @config.max_assignments)
      @resolutions = planner.plan(domains: discovery.domains, roots:)
      errors.concat(resolutions.filter_map do |resolution|
        { operation: "resolve", error: resolution.reason } if %i[resolution_limit no_compatible_solution].include?(resolution.status)
      end)
      installed_security = roots.map do |package|
        baseline = inventory.records.fetch(package).installed
        retained = discovery.domains.fetch(package).find(&:retained)
        formula = package.kind == :formula ? inventory.records.fetch(package).retained&.formula : nil
        patches = formula ? HomebrewAdapter::Advisories.patch_identifiers(formula) : []
        assessment = advisory.assess(release: retained.release, installed: baseline,
                                    candidate_patches: patches, installed_patches: patches)
        selected = resolutions.filter_map { |result| result.selected[package] }.first
        if assessment.evidence.installed_affected && (!selected || selected.retained)
          errors << { operation: "security", package: package.to_h,
                      error: "Installed version has known advisory evidence without an actionable selected upgrade" }
        end
        { package: package.to_h, pinned: baseline.pinned, coverage: assessment.coverage,
          evidence: assessment.evidence.to_h, diagnostics: assessment.diagnostics }
      end
      current = HomebrewAdapter::InstalledInventory.capture(log: @log)
      if current.fingerprint != inventory.fingerprint
        errors << { operation: "inventory_drift", error: "Installed state changed during planning; rerun after package operations finish",
                    changes: Prototype::Inventory.differences(inventory.fingerprint, current.fingerprint),
                    recovery: roots.to_h { |package| [package.name, Prototype::Recovery.commands(package.name)] } }
      end
      errors.concat(current.errors)
      {
        schema: 1, command: "plan", status: errors.empty? ? "assessed" : "incomplete", evaluated_at: @now.iso8601,
        prefix: HOMEBREW_PREFIX.to_s, configuration_digest: @config.digest,
        inventory_digest: Digest::SHA256.hexdigest(JSON.generate(inventory.fingerprint)),
        scope: scope_results.map { |entry| entry.merge(package: entry[:package]&.to_h) },
        components: resolutions.map { |resolution| render_resolution(resolution) },
        candidates: discovery.decisions, installed_security:, errors:,
      }
    end

    private

    def resolve_entry(entry, inventory)
      unless %i[formula cask].include?(entry.kind)
        return { requested: entry.name, kind: entry.kind, status: :outside_scope,
                 reason: "This Brewfile entry does not name a Homebrew package" }
      end
      if entry.name.include?("/")
        package = HomebrewAdapter::InstalledInventory.package(entry.name, kind: entry.kind)
        matches = inventory.records.keys.select { |installed| installed == package }
      else
        matches = inventory.records.keys.select { |installed| installed.kind == entry.kind && installed.name == entry.name }
        if matches.empty? && entry.kind == :formula
          opt = HOMEBREW_PREFIX/"opt"/entry.name
          if opt.symlink? && opt.exist?
            canonical_name = opt.realpath.parent.basename.to_s
            matches = inventory.records.keys.select { |installed| installed.kind == :formula && installed.name == canonical_name }
          end
        end
        package = matches.first || HomebrewAdapter::InstalledInventory.package(entry.name, kind: entry.kind,
                                                                               default_tap: entry.kind == :cask ? "homebrew/cask" : "homebrew/core")
      end
      status, reason = if matches.length > 1
        [:ambiguous, "More than one installed package matches this name; qualify the tap"]
      elsif matches.empty?
        [:missing, "Root package is not installed; scope does not install missing roots"]
      elsif !((package.kind == :formula && package.tap == "homebrew/core") || (package.kind == :cask && package.tap == "homebrew/cask"))
        [:unsupported_executor, "Historical execution for this package type or tap is not available"]
      elsif inventory.records.fetch(package).installed.pinned
        [:pinned, "Explicit Homebrew pin"]
      else
        [:selected, nil]
      end
      { requested: entry.name, package:, status:, reason: }
    end

    def render_resolution(resolution)
      { roots: resolution.roots.map(&:to_h), status: resolution.status, reason: resolution.reason,
        attempts: resolution.attempts, rejected_options: resolution.rejected_options,
        selected: resolution.selected.map do |package, option|
          { package: package.to_h, build: option.release.build.to_h, identity: option.release.identity,
            operation: option.retained ? "retain" : "upgrade", decision: option.decision.to_h }
        end }
    end
  end
end
