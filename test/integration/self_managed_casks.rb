# frozen_string_literal: true

require "open3"
require "tmpdir"
require_relative "../../lib/brew_cooldown/homebrew/installed_inventory"
require_relative "../../lib/brew_cooldown/homebrew/current_cask"

# This probe uses an existing installation and never invokes upgrade. Native
# receipts can lag independent vendor updates, so only their record is asserted.
names = ARGV.empty? ? %w[gcloud-cli tailscale-app] : ARGV
raise "Provide installed official cask tokens" if names.empty?
log = ->(**event) { warn JSON.generate(event) }
before = BrewCooldown::Executor::Inventory.capture
records = names.to_h do |name|
  current = BrewCooldown::HomebrewAdapter::CurrentCask.fetch(name, log:)
  raise "#{name}: provider does not declare independent update capability" unless current.fetch("auto_updates") == true

  [name, BrewCooldown::HomebrewAdapter::InstalledInventory.cask(name)]
end
launcher = File.expand_path("../../bin/brew-cooldown", __dir__)
Dir.mktmpdir("cooldown-self-managed-probe-") do |directory|
  brewfile = Pathname(directory)/"Brewfile"
  brewfile.write(names.map { |name| "cask #{name.dump}\n" }.join)
  with_env(XDG_STATE_HOME: (Pathname(directory)/"state").to_s) do
    stdout, stderr, status = Open3.capture3(launcher, "plan", "--brewfile", brewfile.to_s, "--json")
    warn stderr
    result = JSON.parse(stdout)
    raise "Scope assessment failed: #{result.fetch('errors')}" unless status.success? && result.fetch("status") == "assessed"
    records.each do |name, record|
      package = JSON.parse(JSON.generate(record.installed.package.to_h))
      scoped = result.fetch("scope").find { |row| row["package"] == package }
      raise "#{name}: ownership boundary missing" unless scoped && scoped.fetch("status") == "self_managed" &&
        scoped.fetch("reason").include?("outside cooldown control")
      raise "#{name}: native receipt version lost" unless scoped.fetch("recorded_version") == record.installed.build.version
      raise "#{name}: historical candidate discovery was attempted" if result.fetch("candidates").any? { |row| row["package"] == package }
      raise "#{name}: automatic upgrade proposed" if result.fetch("components").any? do |component|
        component.fetch("selected").any? { |row| row["package"] == package && row["operation"] == "upgrade" }
      end
      record.dependencies.each do |dependency|
        identity = JSON.parse(JSON.generate(dependency.package.to_h))
        raise "#{name}: recorded dependency omitted" unless result.fetch("scope").any? { |row| row["package"] == identity }
      end
      raise "#{name}: unsupported security coverage hidden" unless result.fetch("installed_security").any? do |row|
        row["package"] == package && row["coverage"] == "unsupported_package"
      end
    end
    stdout, stderr, status = Open3.capture3(launcher, "explain", names.first, "--brewfile", brewfile.to_s)
    warn stderr
    raise "Terminal explanation failed or mislabeled the receipt" unless status.success? &&
      stdout.include?("Homebrew-recorded version: #{records.fetch(names.first).installed.build.version}") &&
      stdout.include?("self_managed") && stdout.include?("outside cooldown control")
    puts stdout
  end
end
raise "Read-only assessment changed installed state" unless BrewCooldown::Executor::Inventory.capture == before
puts "PASS: live self-managed scope, receipt versions, dependency visibility and unchanged installed state"
