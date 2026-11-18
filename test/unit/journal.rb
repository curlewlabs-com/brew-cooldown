# frozen_string_literal: true

require "tmpdir"
require_relative "../../lib/brew_cooldown/executor/journal"

# Homebrew permits a formula and cask with the same token. An operation update
# must not mark the other package completed or print the other's repair command.
Dir.mktmpdir("cooldown-journal-") do |directory|
  journal = BrewCooldown::Executor::Journal.new(directory)
  base = { "name" => "shared-token", "version" => "1.0", "status" => "pending", "keg_only" => false }
  journal.with_lock do
    journal.start([base, base.merge("kind" => "cask")], {})
    journal.record("shared-token", "started", kind: "cask")
    loaded = BrewCooldown::Executor::Journal.new(directory)
    report = loaded.report(observed: {})
    formula, cask = report.fetch("operations")
    raise "Cask progress changed formula state" unless formula.fetch("status") == "pending"
    raise "Cask interruption was confirmed" unless cask.fetch("status") == "unconfirmed"
    raise "Cask recovery targets a formula" unless cask.fetch("recovery").all? do |entry|
      Shellwords.split(entry.fetch("command")).include?("--cask")
    end
    raise "Legacy journal lost formula recovery" unless formula.fetch("recovery").all? do |entry|
      Shellwords.split(entry.fetch("command")).include?("--formula")
    end

    journal.record("shared-token", "completed")
    report = BrewCooldown::Executor::Journal.new(directory).report(observed: {})
    raise "Formula progress changed cask state" unless report.fetch("operations").map do |entry|
      entry.fetch("status")
    end == %w[completed unconfirmed]

    # Repair must resolve the tap from the selected operation, rather than
    # let Homebrew choose a same-named package from a different publisher.
    bytes = JSON.parse(journal.path.read)
    bytes.fetch("operations").first["full_name"] = "openai/tools/shared-token"
    journal.path.write(JSON.generate(bytes))
    choices = BrewCooldown::Executor::Journal.new(directory).report(observed: {})
                                             .fetch("operations").first.fetch("recovery")
    raise "Recovery lost selected tap identity" unless choices.all? do |entry|
      Shellwords.split(entry.fetch("command")).include?("openai/tools/shared-token")
    end

    bytes = JSON.parse(journal.path.read)
    bytes.fetch("operations") << base.dup
    journal.path.write(JSON.generate(bytes))
    begin
      BrewCooldown::Executor::Journal.new(directory).load
    rescue BrewCooldown::Executor::Refused => e
      raise unless e.message.include?("duplicate journal operation")

      rejected = true
    end
    raise "Ambiguous journal accepted" unless rejected
  end
end
puts "PASS: typed journal progress, legacy formula compatibility, cask recovery and ambiguous identity rejection"
