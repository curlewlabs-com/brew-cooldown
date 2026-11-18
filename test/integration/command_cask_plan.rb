# frozen_string_literal: true

require "open3"
require "tmpdir"
require "time"
require_relative "../../lib/brew_cooldown/homebrew/installed_inventory"
require_relative "../../lib/brew_cooldown/homebrew/current_cask"

abort "Run only in an expendable VM with historical Codex installed" unless ENV["HOMEBREW_COOLDOWN_DISPOSABLE"] == "1"
cask = BrewCooldown::Executor::CaskRetained.new("codex").cask
raise "Fixture cask must be unpinned" if cask.pinned?

before_version = Version.new(cask.version.to_s)
current = BrewCooldown::HomebrewAdapter::CurrentCask.fetch("codex", log: ->(**_event) {})
launcher = File.expand_path("../../bin/brew-cooldown", __dir__)

Dir.mktmpdir("cooldown-cask-plan-") do |directory|
  brewfile = Pathname(directory)/"Brewfile"
  brewfile.write("cask \"codex\"\n")
  with_env(XDG_STATE_HOME: (Pathname(directory)/"state").to_s) do
    before = BrewCooldown::Executor::Inventory.capture
    stdout, stderr, status = Open3.capture3(launcher, "plan", "--brewfile", brewfile.to_s, "--json")
    warn stderr
    result = JSON.parse(stdout)
    puts JSON.pretty_generate(result)
    raise "Planning changed packages or pins" unless BrewCooldown::Executor::Inventory.capture == before
    raise "Cask planning is incomplete" unless status.success? && result.fetch("status") == "assessed"

    selected = result.fetch("components").flat_map { |component| component.fetch("selected") }
                     .find { |entry| entry.fetch("package").fetch("kind") == "cask" }
    raise "No historical cask upgrade selected" unless selected && selected.fetch("operation") == "upgrade"

    version = Version.new(selected.fetch("build").fetch("version"))
    raise "Cask did not advance" unless version > before_version
    raise "Candidate exceeds current Homebrew source" if version > Version.new(current.fetch("version"))

    latest = result.fetch("candidates").select { |row| row.fetch("build").fetch("version") == current.fetch("version") }
    if latest.any? && latest.all? do |row|
      row.fetch("decision").fetch("status") == "cooldown"
    end && version >= Version.new(current.fetch("version"))
      raise "A currently cooling release was selected"
    end

    decision = selected.fetch("decision")
    unless decision.fetch("status") == "eligible" &&
           Time.iso8601(decision.fetch("eligible_at")) <= Time.iso8601(result.fetch("evaluated_at"))
      raise "Cask did not complete its own cooldown"
    end
    raise "Unknown cask security coverage was hidden" unless result.fetch("installed_security").any? do |row|
      row["coverage"] == "unsupported_package"
    end

    # Native cask pins must enter the same inventory and policy path as formula
    # pins, including when the selected cask has an eligible historical release.
    cask.pin
    begin
      pinned, diagnostics, check = Open3.capture3(launcher, "plan", "--brewfile", brewfile.to_s, "--json")
      warn diagnostics
      report = JSON.parse(pinned)
      raise "Pinned cask assessment failed" unless check.success?
      raise "Native cask pin was omitted" unless report.fetch("scope").any? { |row| row["status"] == "pinned" }

      selections = report.fetch("components").flat_map { |row| row.fetch("selected") }
      if selections.any? { |row| row.fetch("package").fetch("kind") == "cask" && row["operation"] == "upgrade" }
        raise "Pinned cask selected for upgrade"
      end
    ensure
      cask.unpin
    end
    raise "Cask pin test changed installed inventory" unless BrewCooldown::Executor::Inventory.capture == before
  end
end
puts "PASS: historical cask command planning, cooldowns, native pins and unchanged installed state"
