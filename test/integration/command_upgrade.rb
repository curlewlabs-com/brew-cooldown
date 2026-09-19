# frozen_string_literal: true

require "open3"
require "tmpdir"
require_relative "../../lib/brew_cooldown/homebrew/installed_inventory"
require_relative "../../lib/brew_cooldown/executor/execution"

abort "Run only in an expendable VM with historical fixtures" unless ENV["HOMEBREW_COOLDOWN_DISPOSABLE"] == "1"
BrewCooldown::Executor::Execution.check_homebrew!
baseline = { "pcre2" => "10.46", "ripgrep" => "15.0.0" }
partial = ARGV.first == "partial"
mixed = ARGV.first == "mixed"
if mixed
  cask = BrewCooldown::Executor::CaskRetained.new("codex").cask
  raise "Mixed fixture cask is pinned" if cask.pinned?
  cask_version = cask.version.to_s
end
baseline["ruby@3.3"] = "3.3.11" if partial
baseline.each do |name, version|
  raise "Missing baseline #{name}" unless (HOMEBREW_CELLAR/name/version).directory?
  raise "Pinned fixture #{name}" if (HOMEBREW_PINNED_KEGS/name).symlink?
end
launcher = File.expand_path("../../bin/brew-cooldown", __dir__)

def brew!(*arguments)
  raise "Fixture Homebrew operation failed" unless system(HOMEBREW_BREW_FILE.to_s, *arguments)
end

# The fixture owns these formulae in the disposable VM. Remove only inactive
# newer kegs so the command must actually pour, link and verify an upgrade.
brew!("unlink", "--formula", *baseline.keys)
baseline.each do |name, version|
  keg = Keg.new(HOMEBREW_CELLAR/name/version)
  name.start_with?("ruby@") ? keg.optlink : keg.link
  (HOMEBREW_CELLAR/name).children.select(&:directory?).each do |path|
    Keg.new(path).uninstall(raise_failures: true) unless path.basename.to_s == version
  end
end
Dir.mktmpdir("cooldown-upgrade-command-") do |directory|
  state = Pathname(directory)/"state"
  brewfile = Pathname(directory)/"Brewfile"
  brewfile.write(baseline.keys.map { |name| "brew #{name.dump}\n" }.join + (mixed ? "cask \"codex\"\n" : ""))
  with_env(XDG_STATE_HOME: state.to_s) do
    before = BrewCooldown::Executor::Inventory.capture
    # The interpreter's ca-certificates root precedes the PCRE component in
    # runtime scope. Hold its lock so success proves progress after failure.
    held_lock = FormulaLock.new("ruby@3.3") if partial
    held_lock&.lock
    begin
      stdout, stderr, status = Open3.capture3(launcher, "upgrade", "--brewfile", brewfile.to_s, "--json")
    ensure
      held_lock&.unlock
    end
    warn stderr
    raise "No upgrade result" if stdout.empty?
    result = JSON.parse(stdout)
    puts JSON.pretty_generate(result)
    if partial
      execution = result.fetch("execution")
      raise "Independent component did not complete: #{status}" unless status.exitstatus == 1 && result["status"] == "incomplete" &&
        execution.dig(0, "status") == "error" && execution.last&.fetch("status") == "completed"
    else
      raise "Upgrade did not complete: #{status}" unless status.success? && result["status"] == "completed" &&
        result.fetch("execution").any? && result.fetch("execution").all? { |entry| entry["status"] == "completed" }
    end
    baseline.each do |name, version|
      active = Keg.new((HOMEBREW_PREFIX/"opt"/name).realpath)
      if partial && name == "ruby@3.3"
        raise "Failed component changed #{name}" unless active.version == PkgVersion.parse(version)
      else
        raise "#{name} did not advance" unless active.version > PkgVersion.parse(version)
      end
      raise "Installed rebuild was invented" unless BrewCooldown::Executor::Retained.new(active).rebuild.nil?
    end
    raise "No actual package changes" if BrewCooldown::Executor::Inventory.capture == before
    output, check = Open3.capture2((HOMEBREW_PREFIX/"opt/ripgrep/bin/rg").to_s, "--pcre2", "a(?=b)", stdin_data: "ab\n")
    raise "Upgraded runtime is broken" unless check.success? && output == "ab\n"
    if mixed
      # Both installer adapters must share one durable component boundary.
      # A successful cask-only or formula-only run cannot establish this.
      component = result.fetch("execution").find do |entry|
        entry.fetch("operations").any? { |operation| operation["kind"] == "cask" }
      end
      raise "Cask and formula upgrades did not share a component" unless component &&
        component.fetch("operations").any? { |operation| operation["kind"] == "formula" }
      path = cask.metadata_main_container_path/"INSTALL_RECEIPT.json"
      receipt = Cask::Tab.from_file_content(path.read, path)
      raise "Mixed cask did not advance" unless Version.new(receipt.version) > Version.new(cask_version)
      output, check = Open3.capture2((HOMEBREW_PREFIX/"bin/codex").to_s, "--version")
      raise "Mixed cask binary failed" unless check.success? && output.include?(receipt.version)
    end
    raise "Successful journal retained" unless state.glob("**/active.json").empty?
    recovery, check = Open3.capture2(launcher, "recover", "--json")
    raise "Completed upgrade needs recovery" unless check.success? && JSON.parse(recovery)["status"] == "idle"
  end
end
puts "PASS: actual command upgrade, native installation, runtime linkage and journal cleanup"
