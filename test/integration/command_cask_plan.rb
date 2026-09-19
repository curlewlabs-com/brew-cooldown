# frozen_string_literal: true

require "open3"
require "tmpdir"
require "time"
require_relative "../../lib/brew_cooldown/homebrew/installed_inventory"
require_relative "../../lib/brew_cooldown/homebrew/current_cask"

abort "Run only in an expendable VM with historical Codex installed" unless ENV["HOMEBREW_COOLDOWN_DISPOSABLE"] == "1"
cask = BrewCooldown::Prototype::CaskRetained.new("codex").cask
raise "Fixture cask must be unpinned" if cask.pinned?
before_version = Version.new(cask.version.to_s)
current = BrewCooldown::HomebrewAdapter::CurrentCask.fetch("codex", log: ->(**_event) {})
launcher = File.expand_path("../../bin/brew-cooldown", __dir__)

Dir.mktmpdir("cooldown-cask-plan-") do |directory|
  brewfile = Pathname(directory)/"Brewfile"
  brewfile.write("cask \"codex\"\n")
  with_env(XDG_STATE_HOME: (Pathname(directory)/"state").to_s) do
    before = BrewCooldown::Prototype::Inventory.capture
    stdout, stderr, status = Open3.capture3(launcher, "plan", "--brewfile", brewfile.to_s, "--json")
    warn stderr
    result = JSON.parse(stdout)
    puts JSON.pretty_generate(result)
    raise "Planning changed packages or pins" unless BrewCooldown::Prototype::Inventory.capture == before
    raise "Cask planning is incomplete" unless status.success? && result.fetch("status") == "assessed"

    selected = result.fetch("components").flat_map { |component| component.fetch("selected") }
                     .find { |entry| entry.fetch("package").fetch("kind") == "cask" }
    raise "No historical cask upgrade selected" unless selected && selected.fetch("operation") == "upgrade"
    version = Version.new(selected.fetch("build").fetch("version"))
    raise "Cask did not advance" unless version > before_version
    raise "Candidate exceeds current Homebrew source" if version > Version.new(current.fetch("version"))
    latest = result.fetch("candidates").select { |row| row.fetch("build").fetch("version") == current.fetch("version") }
    if latest.any? && latest.all? { |row| row.fetch("decision").fetch("status") == "cooldown" }
      raise "A currently cooling release was selected" unless version < Version.new(current.fetch("version"))
    end
    decision = selected.fetch("decision")
    raise "Cask did not complete its own cooldown" unless decision.fetch("status") == "eligible" &&
      Time.iso8601(decision.fetch("eligible_at")) <= Time.iso8601(result.fetch("evaluated_at"))
    raise "Unknown cask security coverage was hidden" unless result.fetch("installed_security").any? { |row| row["coverage"] == "unsupported_package" }

    # Native cask pins must enter the same inventory and policy path as formula
    # pins, including when the selected cask has an eligible historical release.
    cask.pin
    begin
      pinned, diagnostics, check = Open3.capture3(launcher, "plan", "--brewfile", brewfile.to_s, "--json")
      warn diagnostics
      report = JSON.parse(pinned)
      raise "Pinned cask assessment failed" unless check.success?
      raise "Native cask pin was omitted" unless report.fetch("scope").any? { |row| row["status"] == "pinned" }
      raise "Pinned cask selected for upgrade" if report.fetch("components").flat_map { |row| row.fetch("selected") }.any? do |row|
        row.fetch("package").fetch("kind") == "cask" && row["operation"] == "upgrade"
      end
    ensure
      cask.unpin
    end
    raise "Cask pin test changed installed inventory" unless BrewCooldown::Prototype::Inventory.capture == before
  end
end
puts "PASS: historical cask command planning, cooldowns, native pins and unchanged installed state"
