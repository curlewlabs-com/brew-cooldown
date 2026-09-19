# frozen_string_literal: true

require "stringio"
require "tmpdir"
require_relative "../../lib/brew_cooldown/upgrade"
require_relative "../../lib/brew_cooldown/report"

log = ->(**_event) {}
# Planning is what reads the clock. A preflight that lets planning begin would
# download and attest bottles that this runtime can never install.
planning_started = -> { raise "Planning began on an unqualified runtime" }
unqualified = -> { raise BrewCooldown::Executor::Refused, "Homebrew checkout abc is not the qualified commit" }

Dir.mktmpdir("cooldown-upgrade-preflight-") do |directory|
  upgrade = BrewCooldown::Upgrade.new(config: nil, scope: nil, state_directory: directory, log:,
                                      clock: planning_started, runtime_check: unqualified)
  result = upgrade.call
  raise "Unqualified runtime was not reported: #{result}" unless result.fetch(:status) == "unsupported_runtime" &&
    result.fetch(:errors).first.fetch(:error).include?("not the qualified commit")
  output = StringIO.new
  BrewCooldown::Report.print_upgrade(result, output)
  raise "Terminal output hid the runtime refusal" unless output.string.include?("not the qualified commit")
  # Nothing ran, so there is no unfinished work to send the operator after.
  raise "Refusal before any operation suggested recovery" if output.string.include?("recover")

  # An interrupted upgrade outranks the runtime: its journal needs inspection
  # whichever Homebrew commit is checked out now.
  journal = BrewCooldown::Executor::Journal.new(directory)
  operation = { "name" => "example", "version" => "1.0", "status" => "pending", "keg_only" => false }
  journal.with_lock { journal.start([operation], {}) }
  result = upgrade.call
  raise "Unfinished journal was hidden behind the runtime refusal" unless result.fetch(:status) == "needs_reconciliation"
end
puts "PASS: unqualified runtime refused before planning, after unfinished journals"
