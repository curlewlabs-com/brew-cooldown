# frozen_string_literal: true

require "open3"
require "tmpdir"
require "keg"
require_relative "../../lib/brew_cooldown/state_directory"
require_relative "../../prototype/journal"

launcher = File.expand_path("../../bin/brew-cooldown", __dir__)
before = BrewCooldown::Prototype::Inventory.capture
active = (HOMEBREW_PREFIX/"opt").children.find { |path| path.symlink? && path.exist? && (path/"INSTALL_RECEIPT.json").file? }
raise "Needs an installed Homebrew formula" unless active
keg = Keg.new(active.realpath)

def command(launcher, *arguments)
  stdout, stderr, status = Open3.capture3(launcher, "recover", *arguments, "--json")
  warn stderr unless stderr.empty?
  raise "No structured recovery result: #{stderr}" if stdout.empty?

  [JSON.parse(stdout), status.exitstatus]
end

# The real journal writer and CLI share native inventory evidence. Only product
# state is isolated; the test neither substitutes Homebrew nor changes packages.
Dir.mktmpdir("cooldown-recovery-state-") do |directory|
  with_env(XDG_STATE_HOME: directory) do
    journal = BrewCooldown::Prototype::Journal.new(BrewCooldown::StateDirectory.path)
    warn "Expected journal: #{journal.path}"
    result, code = command(launcher)
    raise "Empty state not reported" unless code.zero? && result["status"] == "idle"
    operation = { "name" => keg.name, "version" => keg.version.to_s, "previous_keg" => keg.to_s,
                  "status" => "pending", "keg_only" => false }
    journal.with_lock do
      journal.start([operation], before)
      journal.record(keg.name, "started")
    end
    original = journal.path.read
    report, code = command(launcher)
    raise "Expected unconfirmed work, got exit #{code}: #{report.inspect}" unless code == 1 &&
      report.fetch("operations").first["status"] == "unconfirmed"
    raise "Inspection modified the journal" unless journal.path.read == original
    raise "Recovery commands omitted" unless report.fetch("operations").first.fetch("recovery").any?
    human, status = Open3.capture2(launcher, "recover")
    raise "Terminal recovery omitted consequences" unless status.exitstatus == 1 && human.include?("outside the cooldown policy") &&
      human.include?("hook completion remains unverified") && human.include?("--accept-current")
    stale = report.fetch("accept_current").fetch("digest")
    if ENV["HOMEBREW_COOLDOWN_DISPOSABLE"] == "1"
      # Only the expendable VM exercises a native package-state race.
      raise "Fixture is already pinned" if (HOMEBREW_PINNED_KEGS/keg.name).symlink?
      raise "Could not pin fixture" unless system(HOMEBREW_BREW_FILE.to_s, "pin", keg.name)
      begin
        rejected, code = command(launcher, "--accept-current", stale)
        raise "Changed inventory accepted" unless code == 1 && rejected["status"] == "error" && journal.path.read == original
      ensure
        raise "Could not restore pin state" unless system(HOMEBREW_BREW_FILE.to_s, "unpin", keg.name)
      end
    end
    journal.with_lock { journal.record(keg.name, "failed", error: "native installer failure") }
    failed_bytes = journal.path.read
    rejected, code = command(launcher, "--accept-current", stale)
    raise "Old acknowledgment cleared new evidence" unless code == 1 && rejected["status"] == "error" && journal.path.read == failed_bytes
    report, = command(launcher)
    accepted, code = command(launcher, "--accept-current", report.fetch("accept_current").fetch("digest"))
    raise "Explicit acknowledgment failed" unless code.zero? && accepted["status"] == "accepted_current" && !journal.path.exist?

    # Corrupt state stays available for diagnosis and is never acknowledged.
    ["{", JSON.generate("schema" => 1, "prefix" => HOMEBREW_PREFIX.realpath.to_s,
                        "inventory" => before, "operations" => [operation.reject { |key, _| key == "version" }])].each do |bytes|
      journal.path.write(bytes)
      result, code = command(launcher)
      raise "Malformed journal not preserved" unless code == 1 && result["status"] == "error" && journal.path.read == bytes
    end
  end
  with_env(XDG_CONFIG_HOME: directory) do
    config = Pathname(directory)/"brew-cooldown/config.json"
    config.dirname.mkpath
    config.write(JSON.generate("unknown_option" => true))
    stdout, status = Open3.capture2(launcher, "plan", "--json")
    result = JSON.parse(stdout)
    raise "Launcher lost configured XDG directory" unless status.exitstatus == 1 && result.fetch("error").include?("Unknown configuration keys")
  end
end
raise "Recovery changed packages or pins" unless BrewCooldown::Prototype::Inventory.capture == before
puts "PASS: command recovery, unconfirmed work, stale acknowledgment, explicit acceptance and malformed journals"
