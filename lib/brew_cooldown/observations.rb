# frozen_string_literal: true

require "json"
require "pathname"
require "tempfile"
require "time"

module BrewCooldown
  class StateError < StandardError; end

  # Only fallback clocks and the last observed UTC instant survive a run.
  # Candidate recipes, downloads and history remain owned by Homebrew.
  class Observations
    def initialize(directory, prefix:)
      @directory = Pathname(directory)
      @directory.mkpath
      @prefix = Pathname(prefix).realpath.to_s
      @path = @directory/"observations.json"
    end

    def remember_clock(now:)
      update(now:) { |_observed| nil }
    end

    def first_seen(release, now:)
      unless release.verified && release.identity.is_a?(String) && release.identity.match?(/\A[0-9a-f]{64}\z/)
        raise StateError, "cannot record an observation without a verified candidate identity"
      end

      update(now:) do |observed|
        observed[release.identity] ||= now.getutc.iso8601(9)
        Time.iso8601(observed.fetch(release.identity))
      end
    end

    private

    def update(now:)
      File.open(@directory/"run.lock", File::RDWR | File::CREAT, 0600) do |lock|
        raise StateError, "another brew-cooldown invocation owns #{@directory}" unless lock.flock(File::LOCK_EX | File::LOCK_NB)

        state = load_state
        previous = state.fetch("last_seen")
        if previous && now < Time.iso8601(previous)
          raise StateError, "UTC clock moved backward: #{now.getutc.iso8601} precedes #{previous}"
        end
        state["last_seen"] = now.getutc.iso8601(9)
        result = yield state.fetch("observed")
        persist(state)
        result
      end
    end

    def load_state
      return { "schema" => 1, "prefix" => @prefix, "last_seen" => nil, "observed" => {} } unless @path.exist?

      state = JSON.parse(@path.read)
      unless state.is_a?(Hash) && state["schema"] == 1 && state["prefix"] == @prefix &&
             state["observed"].is_a?(Hash) && state.key?("last_seen")
        raise StateError, "unsupported or mismatched observation state: #{@path}"
      end
      Time.iso8601(state["last_seen"]) if state["last_seen"]
      state.fetch("observed").each do |identity, timestamp|
        raise StateError, "invalid candidate identity in #{@path}" unless identity.match?(/\A[0-9a-f]{64}\z/)

        Time.iso8601(timestamp)
      end
      state
    rescue JSON::ParserError, ArgumentError, TypeError => error
      raise StateError, "cannot read observation state #{@path}: #{error.message}"
    end

    def persist(state)
      Tempfile.create(["observations-", ".json"], @directory) do |file|
        file.write(JSON.generate(state))
        file.flush
        file.fsync
        File.rename(file.path, @path)
        File.open(@directory, File::RDONLY, &:fsync)
      end
    end
  end
end
