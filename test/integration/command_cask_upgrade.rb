# frozen_string_literal: true

require "open3"
require "tmpdir"
require "time"
require_relative "../../lib/brew_cooldown/homebrew/installed_inventory"

abort "Run only in an expendable VM with historical Codex installed" unless ENV["HOMEBREW_COOLDOWN_DISPOSABLE"] == "1"
before_cask = BrewCooldown::Prototype::CaskRetained.new("codex").cask
raise "Fixture cask must be unpinned" if before_cask.pinned?
before_version = Version.new(before_cask.version.to_s)
launcher = File.expand_path("../../bin/brew-cooldown", __dir__)

Dir.mktmpdir("cooldown-cask-upgrade-") do |directory|
  brewfile = Pathname(directory)/"Brewfile"
  brewfile.write("cask \"codex\"\n")
  state = Pathname(directory)/"state"
  with_env(XDG_STATE_HOME: state.to_s) do
    before = BrewCooldown::Prototype::Inventory.capture
    stdout, stderr, status = Open3.capture3(launcher, "upgrade", "--brewfile", brewfile.to_s, "--json")
    warn stderr
    result = JSON.parse(stdout)
    puts JSON.pretty_generate(result)
    raise "Cask upgrade did not complete" unless status.success? && result.fetch("status") == "completed"

    operations = result.fetch("execution").flat_map { |component| component.fetch("operations") }
    operation = operations.find { |entry| entry.fetch("kind") == "cask" && entry.fetch("name") == "codex" }
    raise "Cask completion missing" unless operation && operation.fetch("status") == "completed"
    raise "Cask did not advance" unless Version.new(operation.fetch("version")) > before_version
    # Completion must describe the exact selected source, not merely any newer
    # installed version that a native current-recipe fallback might produce.
    path = before_cask.metadata_main_container_path/"INSTALL_RECEIPT.json"
    receipt = Cask::Tab.from_file_content(path.read, path)
    raise "Wrong installed version" unless receipt.version == operation.fetch("version")
    raise "Wrong source provenance" unless receipt.source.fetch("tap_git_head") == operation.fetch("candidate").fetch("commit")
    selected = result.fetch("components").flat_map { |component| component.fetch("selected") }
                     .find { |entry| entry.fetch("package").fetch("kind") == "cask" }
    raise "Installed version differs from plan" unless selected.fetch("build").fetch("version") == receipt.version
    raise "Selected cask had not completed its cooldown" unless Time.iso8601(selected.fetch("decision").fetch("eligible_at")) <=
      Time.iso8601(result.fetch("evaluated_at"))
    output, check = Open3.capture2((HOMEBREW_PREFIX/"bin/codex").to_s, "--version")
    raise "Installed binary does not run" unless check.success? && output.include?(receipt.version)
    raise "Generated completions missing" unless (HOMEBREW_PREFIX/"share/zsh/site-functions/_codex").size.positive?
    after = BrewCooldown::Prototype::Inventory.capture
    changes = BrewCooldown::Prototype::Inventory.differences(before, after)
    raise "Cask upgrade changed formula inventory" unless changes.any? && changes.all? { |entry| entry.fetch("path").start_with?("#{before_cask.caskroom_path}/") }
    raise "Completed journal remained" unless state.glob("**/active.json").empty?
    report, diagnostics, check = Open3.capture3(launcher, "recover", "--json")
    warn diagnostics
    raise "Completed cask upgrade needs recovery" unless check.success? && JSON.parse(report).fetch("status") == "idle"
  end
end
puts "PASS: cask command upgrade, native source receipt, binary, completions, retained formulae and journal cleanup"
