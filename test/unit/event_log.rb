# frozen_string_literal: true

require "stringio"
require_relative "../../lib/brew_cooldown/event_log"

# A scheduled run took over half an hour, and its log could not say where:
# events carried no time. Each now records seconds since the command began,
# read from the injected clock, without disturbing the event's own fields.
readings = [1000.0, 1000.25, 1062.5004]
io = StringIO.new
log = BrewCooldown::EventLog.new(io:, clock: -> { readings.shift })
log.call(operation: "read_registry", url: "https://ghcr.io/v2/homebrew/core/git/tags/list")
log.call(operation: "phase", phase: "resolve")
events = io.string.lines.map { |line| JSON.parse(line) }
raise "Expected one JSON object per line: #{io.string}" unless events.length == 2
expected = [{ "operation" => "read_registry", "url" => "https://ghcr.io/v2/homebrew/core/git/tags/list", "elapsed_seconds" => 0.25 },
            { "operation" => "phase", "phase" => "resolve", "elapsed_seconds" => 62.5 }]
raise "Unexpected events: #{events}" unless events == expected
puts "PASS: structured events carry elapsed time from the injected clock"
