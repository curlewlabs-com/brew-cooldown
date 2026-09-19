# frozen_string_literal: true

module BrewCooldown
  # The adapter supplies immutable candidate identity and evaluated advisory
  # evidence. Policy decisions never fetch metadata or read the system clock.
  PackageId = Data.define(:kind, :tap, :name)
  Build = Data.define(:version, :revision, :rebuild, :scheme)
  Release = Data.define(:package, :build, :identity, :verified, :published_at, :publication_source)
  Installed = Data.define(:package, :build, :pinned)
  SecurityEvidence = Data.define(:installed_affected, :candidate_affected, :fixed_advisories, :validated_at)

  Decision = Data.define(:status, :reason, :eligible_at, :delay_kind, :age_source, :fixed_advisories) do
    def eligible?
      %i[eligible security_fix].include?(status)
    end
  end

  class Policy
    DEFAULT_DELAYS = { patch: 14, minor: 21, major: 60, default: 14 }.freeze
    # Elapsed UTC days avoid local-midnight and daylight-saving discontinuities.
    SECONDS_PER_DAY = 86_400
    SECURITY_FRESHNESS = 3600
    STABLE_SEMVER = /\A([1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\z/

    def initialize(compare_builds:, delays: {})
      unknown = delays.keys - DEFAULT_DELAYS.keys
      raise ArgumentError, "unknown cooldown classes: #{unknown.join(', ')}" unless unknown.empty?
      raise ArgumentError, "cooldown days must be nonnegative integers" unless
        delays.values.all? { |days| days.is_a?(Integer) && days >= 0 }

      @delays = DEFAULT_DELAYS.merge(delays).freeze
      @compare_builds = compare_builds
    end

    def evaluate(release:, installed:, now:, security:, first_seen: nil, clock_floor: nil)
      if installed && installed.package != release.package
        raise ArgumentError, "installed and candidate package identities differ"
      end
      return decision(:pinned, "Explicit Homebrew pin") if installed&.pinned
      unless release.verified && release.identity.is_a?(String) && release.identity.match?(/\A[0-9a-f]{64}\z/)
        return decision(:unverified, "Exact candidate identity has not been verified")
      end
      if installed && @compare_builds.call(release.build, installed.build) <= 0
        return decision(:not_newer, "Candidate does not advance the active installation")
      end
      if clock_floor && now < clock_floor
        return decision(:clock_regression, "Current UTC time precedes the last recorded observation")
      end
      if security.candidate_affected
        return decision(:affected, "Candidate remains affected by known advisory evidence")
      end

      origin = release.published_at || first_seen
      source = release.published_at ? release.publication_source : :first_observation
      if origin && origin > now
        return decision(:invalid_time, "Candidate age evidence is in the future")
      end
      if release.published_at && !release.publication_source
        return decision(:invalid_time, "Publication time has no evidence source")
      end

      kind = delay_kind(installed&.build, release.build)
      eligible_at = origin && origin + @delays.fetch(kind) * SECONDS_PER_DAY
      if security_exception?(security, installed, now)
        return decision(:security_fix, "Fresh advisory evidence proves an installed vulnerability is fixed",
                        eligible_at: now, delay_kind: kind, age_source: source,
                        fixed_advisories: security.fixed_advisories)
      end
      unless origin
        return decision(:needs_observation, "Record a first verified observation to start the candidate's wait",
                        delay_kind: kind, age_source: source)
      end

      if now >= eligible_at
        decision(:eligible, "Candidate completed its cooldown", eligible_at:, delay_kind: kind, age_source: source)
      else
        decision(:cooldown, "Candidate is still cooling down", eligible_at:, delay_kind: kind, age_source: source)
      end
    end

    private

    def delay_kind(installed, candidate)
      return :default unless installed && installed.scheme == candidate.scheme

      before = STABLE_SEMVER.match(installed.version)
      after = STABLE_SEMVER.match(candidate.version)
      return :default unless before && after

      old_parts = before.captures.map(&:to_i)
      new_parts = after.captures.map(&:to_i)
      return :major if new_parts[0] != old_parts[0]
      return :minor if new_parts[1] != old_parts[1]
      return :patch if new_parts[2] != old_parts[2]

      :default
    end

    def security_exception?(security, installed, now)
      installed && security.installed_affected == true && security.candidate_affected == false &&
        !security.fixed_advisories.empty? && security.validated_at &&
        security.validated_at <= now && now - security.validated_at <= SECURITY_FRESHNESS
    end

    def decision(status, reason, eligible_at: nil, delay_kind: nil, age_source: nil, fixed_advisories: [])
      Decision.new(status:, reason:, eligible_at:, delay_kind:, age_source:,
                   fixed_advisories: fixed_advisories.dup.freeze)
    end
  end
end
