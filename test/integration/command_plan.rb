# frozen_string_literal: true

require "open3"
require "tmpdir"
require_relative "../../lib/brew_cooldown/homebrew/installed_inventory"

abort "Run only in an expendable VM with the historical installer fixtures" unless ENV["HOMEBREW_COOLDOWN_DISPOSABLE"] == "1"
names = %w[pcre2 ripgrep]
baseline = { "pcre2" => "10.46", "ripgrep" => "15.0.0" }
previous = names.to_h { |name| [name, (HOMEBREW_PREFIX/"opt"/name).realpath] }
abort "Planning fixture packages must be unpinned" if names.any? { |name| (HOMEBREW_PINNED_KEGS/name).symlink? }
baseline.each { |name, version| raise "Missing historical #{name} keg" unless (HOMEBREW_CELLAR/name/version).directory? }

def brew!(*arguments)
  raise "Homebrew command failed: #{arguments.join(' ')}" unless system(HOMEBREW_BREW_FILE.to_s, *arguments)
end

def run_plan(brewfile)
  command = File.expand_path("../../bin/brew-cooldown", __dir__)
  before = BrewCooldown::Executor::Inventory.capture
  stdout, stderr, status = Open3.capture3(command, "plan", "--brewfile", brewfile.to_s, "--json")
  raise "Planning changed installed packages or pins" unless BrewCooldown::Executor::Inventory.capture == before
  if stdout.empty?
    warn stderr
    raise "Plan command returned no JSON (exit #{status.exitstatus})"
  end
  result = JSON.parse(stdout)
  unless [0, 1].include?(status.exitstatus) && result["command"] == "plan" && result["schema"] == 1
    warn stderr
    raise "Command did not return a structured plan: #{stdout}"
  end
  result
end

begin
  brew!("unlink", "--formula", *names)
  baseline.each { |name, version| Keg.new(HOMEBREW_CELLAR/name/version).link }
  Dir.mktmpdir("cooldown-command-plan-") do |directory|
    brewfile = Pathname(directory)/"Brewfile"
    brewfile.write("brew \"pcre2\"\nbrew \"ripgrep\"\n")
    result = run_plan(brewfile)
    selected = result.fetch("components").flat_map { |component| component.fetch("selected") }
    names.each do |name|
      option = selected.find { |entry| entry.fetch("package").fetch("name") == name }
      raise "No advancing #{name} selected: #{result.inspect}" unless option && option["operation"] == "upgrade" &&
        Version.new(option.fetch("build").fetch("version")) > Version.new(baseline.fetch(name))
    end
    raise "Candidate decisions missing" if result.fetch("candidates").empty?
    result.fetch("candidates").each do |entry|
      boundary = entry.fetch("decision")["eligible_at"]
      Time.iso8601(boundary) if boundary
    end

    brew!("pin", "pcre2")
    pinned = run_plan(brewfile)
    raise "Pin not visible in scope" unless pinned.fetch("scope").any? { |entry| entry["requested"] == "pcre2" && entry["status"] == "pinned" }
    raise "Pinned root selected for mutation" if pinned.fetch("components").flat_map { |component| component.fetch("selected") }.any? do |entry|
      entry.fetch("package").fetch("name") == "pcre2" && entry["operation"] != "retain"
    end
    brew!("unpin", "pcre2")
    puts "PASS: live historical planning, clean JSON, pins and unchanged installed state"
  end
ensure
  brew!("unpin", "pcre2") if (HOMEBREW_PINNED_KEGS/"pcre2").symlink?
  brew!("unlink", "--formula", *names)
  previous.each_value { |path| Keg.new(path).link }
end
