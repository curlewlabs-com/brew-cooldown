# frozen_string_literal: true

require "open3"
require "tmpdir"
require_relative "../../lib/brew_cooldown/homebrew/installed_inventory"
require_relative "../../prototype/execution"

abort "Run only in an expendable VM with historical fixtures" unless ENV["HOMEBREW_COOLDOWN_DISPOSABLE"] == "1"
BrewCooldown::Prototype::Execution.check_homebrew!
baseline = { "pcre2" => "10.46", "ripgrep" => "15.0.0" }
partial = ARGV.first == "partial"
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
  brewfile.write(baseline.keys.map { |name| "brew #{name.dump}\n" }.join)
  with_env(XDG_STATE_HOME: state.to_s) do
    before = BrewCooldown::Prototype::Inventory.capture
    # Contend on a real native package lock; a separate dependency component
    # must still make progress after this one fails before installation.
    held_lock = FormulaLock.new("pcre2") if partial
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
      raise "Independent component did not complete: #{status}" unless status.exitstatus == 1 && result["status"] == "incomplete" &&
        result.fetch("execution").first["status"] == "error" && result.fetch("execution").last["status"] == "completed"
    else
      raise "Upgrade did not complete: #{status}" unless status.success? && result["status"] == "completed" &&
        result.fetch("execution").any? && result.fetch("execution").all? { |entry| entry["status"] == "completed" }
    end
    baseline.each do |name, version|
      active = Keg.new((HOMEBREW_PREFIX/"opt"/name).realpath)
      if partial && name != "ruby@3.3"
        raise "Failed component changed #{name}" unless active.version == PkgVersion.parse(version)
      else
        raise "#{name} did not advance" unless active.version > PkgVersion.parse(version)
      end
      raise "Installed rebuild was invented" unless BrewCooldown::Prototype::Retained.new(active).rebuild.nil?
    end
    raise "No actual package changes" if BrewCooldown::Prototype::Inventory.capture == before
    output, check = Open3.capture2((HOMEBREW_PREFIX/"opt/ripgrep/bin/rg").to_s, "--pcre2", "a(?=b)", stdin_data: "ab\n")
    raise "Upgraded runtime is broken" unless check.success? && output == "ab\n"
    raise "Successful journal retained" unless state.glob("**/active.json").empty?
    recovery, check = Open3.capture2(launcher, "recover", "--json")
    raise "Completed upgrade needs recovery" unless check.success? && JSON.parse(recovery)["status"] == "idle"
  end
end
puts "PASS: actual command upgrade, native installation, runtime linkage and journal cleanup"
