# frozen_string_literal: true

require "json"

module BrewCooldown
  # Structured operation events, one JSON object per stderr line. Each carries
  # the seconds since the command began, so a slow run's log shows where its
  # time went: the gap before an event is the work that led up to it. A
  # monotonic clock keeps that true across wall-clock changes and into a
  # forked component, which inherits the same start.
  class EventLog
    def initialize(io: $stderr, clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
      @io, @clock = io, clock
      @start = clock.call
    end

    def call(**event)
      @io.puts(JSON.generate(event.merge(elapsed_seconds: (@clock.call - @start).round(3))))
    end
  end
end
