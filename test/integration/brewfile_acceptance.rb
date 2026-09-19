# frozen_string_literal: true

require "open3"
require "tmpdir"
require_relative "../../lib/brew_cooldown/homebrew/installed_inventory"
require_relative "../../lib/brew_cooldown/homebrew/scope"
require_relative "../../lib/brew_cooldown/executor/execution"

abort "Run only in a provisioned expendable VM" unless ENV["HOMEBREW_COOLDOWN_DISPOSABLE"] == "1"
BrewCooldown::Executor::Execution.check_homebrew!
brewfile = Pathname(ENV.fetch("HOMEBREW_COOLDOWN_TEST_BREWFILE")).realpath
launcher = File.expand_path("../../bin/brew-cooldown", __dir__)
profile = File.expand_path("../../examples/conservative.json", __dir__)
entries = BrewCooldown::HomebrewAdapter::Scope.read({ brewfile: }, installed: [])
expected_roots = entries.select { |entry| %i[formula cask].include?(entry.kind) }
                       .map { |entry| [entry.name, entry.kind.to_s] }.sort
raise "Acceptance Brewfile needs formula and cask entries" unless expected_roots.any? { |_name, kind| kind == "formula" } &&
  expected_roots.any? { |_name, kind| kind == "cask" }

Dir.mktmpdir("cooldown-brewfile-acceptance-") do |directory|
  with_env(XDG_STATE_HOME: directory) do
    %w[plan upgrade].each do |command|
      warn "Checking full Brewfile #{command}"
      before = BrewCooldown::Executor::Inventory.capture
      stdout, status = Open3.capture2(launcher, command, "--brewfile", brewfile.to_s, "--config", profile, "--json", err: STDERR)
      result = JSON.parse(stdout)
      puts JSON.pretty_generate(command:, result:)
      expected_status = command == "plan" ? "assessed" : "completed"
      raise "Full Brewfile #{command} did not complete" unless status.success? && result.fetch("status") == expected_status
      roots = result.fetch("scope").select { |entry| entry["package"] && entry["origin"] != "runtime_dependency" }
                    .map { |entry| [entry.fetch("requested"), entry.fetch("package").fetch("kind")] }.sort
      raise "A declared Brewfile package was omitted" unless roots == expected_roots
      # A complete status is meaningful only when missing or unsupported scope
      # remains impossible to hide behind successful independent components.
      raise "A Brewfile package is unassessed" unless result.fetch("scope").all? { |entry| %w[selected pinned outside_scope].include?(entry.fetch("status")) }
      if command == "plan"
        raise "Planning mutated installed packages or pins" unless BrewCooldown::Executor::Inventory.capture == before
      else
        raise "An upgrade component did not complete" unless result.fetch("execution").all? { |entry| entry.fetch("status") == "completed" }
        if ENV["HOMEBREW_COOLDOWN_TEST_REQUIRE_UPGRADE"] == "1"
          operations = result.fetch("execution").flat_map { |entry| entry.fetch("operations") }
          raise "Upgrade qualification requires a completed installation" unless operations.any? &&
            operations.all? { |entry| entry.fetch("status") == "completed" } &&
            BrewCooldown::Executor::Inventory.capture != before
        end
      end
    end
    stdout, status = Open3.capture2(launcher, "recover", "--json", err: STDERR)
    raise "Full Brewfile execution left unfinished work" unless status.success? && JSON.parse(stdout).fetch("status") == "idle"
  end
end
puts "PASS: complete Brewfile scope, conservative profile, native plan/upgrade workflow and clean recovery"
