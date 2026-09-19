# frozen_string_literal: true

require "open3"
require "tmpdir"
require_relative "../../lib/brew_cooldown/homebrew/installed_inventory"

abort "Run only in a disposable VM with Codex installed" unless ENV["HOMEBREW_COOLDOWN_DISPOSABLE"] == "1"
launcher = File.expand_path("../../bin/brew-cooldown", __dir__)
before = BrewCooldown::Executor::Inventory.capture
version = BrewCooldown::Executor::CaskRetained.new("codex").cask.version.to_s

Dir.mktmpdir("cooldown-explain-") do |directory|
  brewfile = Pathname(directory)/"Brewfile"
  brewfile.write("cask \"codex\"\n")
  cache = Pathname(directory)/"cache"
  # A fresh native cache proves source history and artifact discovery do not
  # depend on downloads left behind by the historical installation fixtures.
  with_env(XDG_STATE_HOME: (Pathname(directory)/"state").to_s, HOMEBREW_CACHE: cache.to_s) do
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
    raise "Cold-cache qualification needs historical candidate discovery" unless result.fetch("candidates").any? do |row|
      row.fetch("package").fetch("name") == "codex" && row.fetch("decision")["age_source"] == "homebrew_source_commit"
    end
    raise "Qualification did not use its fresh native cache" unless (cache/"downloads").directory? &&
      (cache/"downloads").children.any?
  end
end
raise "Explanation changed packages or pins" unless BrewCooldown::Executor::Inventory.capture == before
puts "PASS: cold-cache native package explanation, full assessment and unchanged installed state"
