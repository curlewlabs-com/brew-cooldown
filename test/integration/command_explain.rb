# frozen_string_literal: true

require "open3"
require "tmpdir"
require_relative "../../lib/brew_cooldown/homebrew/installed_inventory"

abort "Run only in a disposable VM with Codex installed" unless ENV["HOMEBREW_COOLDOWN_DISPOSABLE"] == "1"
launcher = File.expand_path("../../bin/brew-cooldown", __dir__)
before = BrewCooldown::Prototype::Inventory.capture
version = BrewCooldown::Prototype::CaskRetained.new("codex").cask.version.to_s

Dir.mktmpdir("cooldown-explain-") do |directory|
  brewfile = Pathname(directory)/"Brewfile"
  brewfile.write("cask \"codex\"\n")
  with_env(XDG_STATE_HOME: (Pathname(directory)/"state").to_s) do
    stdout, status = Open3.capture2(launcher, "explain", "cask:homebrew/cask/codex", "--brewfile", brewfile.to_s, "--json", err: STDERR)
    result = JSON.parse(stdout)
    puts JSON.pretty_generate(result)
    raise "Explanation did not complete" unless status.success? && result.fetch("command") == "explain" && result.fetch("status") == "assessed"
    explanation = result.fetch("explanation")
    raise "Wrong native installed baseline" unless explanation.fetch("status") == "matched" &&
      explanation.fetch("package") == { "kind" => "cask", "tap" => "homebrew/cask", "name" => "codex" } &&
      explanation.fetch("installed").fetch("build").fetch("version") == version
    raise "Explanation discarded the full plan" unless result.fetch("scope").any? && result.fetch("components").any? &&
      result.fetch("installed_security").any? { |row| row["coverage"] == "unsupported_package" }
  end
end
raise "Explanation changed packages or pins" unless BrewCooldown::Prototype::Inventory.capture == before
puts "PASS: native package explanation, full assessment and unchanged installed state"
