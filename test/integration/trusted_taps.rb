# frozen_string_literal: true

require "open3"
require "tmpdir"

abort "Run only in an expendable Apple Silicon VM" unless ENV["HOMEBREW_COOLDOWN_DISPOSABLE"] == "1"
require_relative "../../lib/brew_cooldown/upgrade"
require_relative "../../lib/brew_cooldown/recovery"
require_relative "../../lib/brew_cooldown/homebrew/tap_history"
require_relative "../../lib/brew_cooldown/report"
BrewCooldown::Executor::Execution.check_homebrew!

STATE = Pathname(ENV.fetch("HOMEBREW_COOLDOWN_TEST_STATE"))
LOG = ->(**event) { warn JSON.generate(BrewCooldown::Report.json_value(event)) }
NOW = Time.iso8601("2026-10-08T06:30:00Z")
PACKAGE = BrewCooldown::PackageId.new(kind: :formula, tap: "openai/tools", name: "tart")
# These live upstream commits predate the cooling releases. Fixed timestamps
# make historical selection reproducible after those newer releases mature.
BASELINE = { "tart" => "2b0b3deb1c45b6a829e358fa5d1ae28f4036d141",
             "softnet" => "b9d22f7eef6cea4d9ad4c84459527447363e8014" }.freeze

phase = ARGV.fetch(0)
if phase == "crash_check"
  output, status = Open3.capture2e(HOMEBREW_BREW_FILE.to_s, "ruby", "--", __FILE__, "interrupt")
  puts output
  raise "Expected SIGKILL at a durable package boundary: #{status}" unless status.signaled? && status.termsig == Signal.list.fetch("KILL")
  exit
end

if phase == "recover"
  journals = BrewCooldown::Journals.new(STATE)
  before = BrewCooldown::Executor::Inventory.capture
  recovery = BrewCooldown::Recovery.new(state_directory: STATE, log: LOG)
  report = recovery.call
  raise "Interrupted release installation lost its journal: #{report}" unless report.fetch(:status) == "needs_reconciliation"
  operations = report.fetch(:operations)
  raise "Started installation was certified completed" unless operations.any? { |operation| operation.fetch("status") == "unconfirmed" }
  raise "Pending dependency/root was lost" unless operations.any? { |operation| operation.fetch("status") == "pending" }
  raise "Recovery omitted inspection choices" unless operations.all? { |operation| operation.fetch("recovery").any? }
  accepted = recovery.call(accept_current: report.fetch(:accept_current).fetch("digest"))
  raise "Explicit recovery failed: #{accepted}" unless accepted.fetch(:status) == "accepted_current"
  raise "Recovery changed installed packages" unless before == BrewCooldown::Executor::Inventory.capture
  raise "Recovery retained unfinished journal" unless journals.pending.empty?
  puts "PASS: interrupted trusted-tap installation remains unconfirmed until explicit recovery"
  exit
end

if phase == "baseline"
  candidates = BASELINE.map do |name, commit|
    history = BrewCooldown::HomebrewAdapter::TapHistory.new(package: PACKAGE.with(name:), log: LOG, now: NOW).refresh
    candidate = history.candidate(BrewCooldown::HomebrewAdapter::TapHistoryEntry.new(commit:, published_at: nil)).prepare
    raise "Baseline package already installed" if candidate.formula.opt_prefix.exist?
    candidate
  end
  map = BrewCooldown::Executor::ExactMap.new(candidates)
  map.activate
  result = BrewCooldown::Executor::Execution.new(map, state_directory: STATE/"baseline")
                                          .apply(expected_inventory: BrewCooldown::Executor::Inventory.capture)
  raise "Historical release baseline failed: #{result}" unless result.fetch("status") == "completed"
  puts "PASS: exact historical Tart and softnet installed with native recipes, receipts and links"
  exit
end

config = BrewCooldown::Config.new({ "trusted_taps" => ["openai/tools"] }, directory: STATE)
scope = { installed: true }
planning = BrewCooldown::Planning.new(config:, scope:, now: NOW, log: LOG, state_directory: STATE)
plan = planning.call
raise "Trusted tap assessment failed: #{plan[:errors]}" unless plan.fetch(:status) == "assessed"
resolution = planning.resolutions.find { |entry| entry.selected.key?(PACKAGE) }
raise "Tart is not selected" unless resolution
selected = resolution.selected.fetch(PACKAGE)
raise "Newer cooling release suppressed historical upgrade" unless selected.release.build.version == "2.37.0" && !selected.retained
softnet = PACKAGE.with(name: "softnet")
raise "Dependency failed its own historical cooldown" unless resolution.selected.fetch(softnet).release.build.version == "0.23.0"
raise "Latest candidate not reported cooling" unless plan.fetch(:candidates).any? do |candidate|
  candidate.fetch(:package) == PACKAGE.to_h && candidate.fetch(:build).fetch(:version) == "2.40.1" && candidate.fetch(:decision).fetch(:status) == :cooldown
end

if phase == "assessment"
  # Native pins and trust affect actual command assessment, not just planner
  # fixtures. Scope still traverses Tart's installed runtime dependency.
  # The isolated prefix has no live tap checkout. Native short-name resolution
  # reads the installed keg recipe instead of requiring today's tap formula.
  output, status = Open3.capture2e(HOMEBREW_BREW_FILE.to_s, "pin", "--formula", "tart")
  raise "Cannot pin Tart: #{output}" unless status.success?
  begin
    pinned = BrewCooldown::Planning.new(config:, scope:, now: NOW, log: LOG, state_directory: STATE).call
    raise "Pin did not retain Tart" unless pinned.fetch(:scope).any? { |entry| entry[:package] == PACKAGE.to_h && entry[:status] == :pinned }
    raise "Pin suppressed dependency assessment" unless pinned.fetch(:scope).any? { |entry| entry[:package] == softnet.to_h && entry[:status] == :selected }
    untrusted = BrewCooldown::Config.new({}, directory: STATE)
    untrusted_plan = BrewCooldown::Planning.new(config: untrusted, scope:, now: NOW, log: LOG, state_directory: STATE).call
    raise "Untrusted dependency was accepted" unless untrusted_plan.fetch(:status) == "incomplete" &&
      untrusted_plan.fetch(:scope).any? { |entry| entry[:package] == softnet.to_h && entry[:status] == :unsupported_executor }
    raise "Unsupported pinned root required an executor" unless untrusted_plan.fetch(:scope).any? { |entry| entry[:package] == PACKAGE.to_h && entry[:status] == :pinned }
  ensure
    output, status = Open3.capture2e(HOMEBREW_BREW_FILE.to_s, "unpin", "--formula", "tart")
    raise "Cannot unpin fixture: #{output}" unless status.success?
  end
  puts "PASS: live historical candidate ages, runtime dependency cooldowns, trust refusal and native pins"
  exit
end

if phase == "interrupt"
  candidates = resolution.selected.values.map { |option| planning.discovery.prepared.fetch(option.release.identity) }
  map = BrewCooldown::Executor::ExactMap.new(candidates)
  map.activate
  execution = BrewCooldown::Executor::Execution.new(map, state_directory: BrewCooldown::Journals.new(STATE).component_directory(resolution.selected.keys))
  execution.apply(expected_inventory: planning.inventory.fingerprint) do |name, status|
    Process.kill("KILL", Process.pid) if name == "softnet" && status == "started"
  end
  raise "Durable interruption boundary was never reached"
end
raise "Unknown phase #{phase}" unless phase == "upgrade"

result = BrewCooldown::Upgrade.new(config:, scope:, state_directory: STATE, log: LOG, clock: -> { NOW }).call
puts JSON.pretty_generate(BrewCooldown::Report.json_value(result))
raise "Trusted historical upgrade failed" unless result.fetch(:status) == "completed"
{ "tart" => "2.37.0", "softnet" => "0.23.0" }.each do |name, version|
  opt = HOMEBREW_PREFIX/"opt"/name
  keg = Keg.new(opt.realpath)
  tab = Tab.for_keg(keg)
  raise "Wrong native installed release" unless keg.version.to_s == version && tab.tap == "openai/tools" && !tab.poured_from_bottle
  raise "Missing selected historical recipe" unless (keg/".brew/#{name}.rb").file?
  raise "Canonical link is missing" unless (HOMEBREW_LINKED_KEGS/name).realpath == opt.realpath
end
output, status = Open3.capture2e((HOMEBREW_PREFIX/"opt/tart/bin/tart").to_s, "--version")
raise "Installed Tart did not execute: #{output}" unless status.success? && output.include?("2.37.0")
raise "Tart native completion hook did not run" unless (HOMEBREW_PREFIX/"opt/tart/share/zsh/site-functions").glob("*").any?
raise "Completed upgrade retained journals" unless BrewCooldown::Journals.new(STATE).pending.empty?

# A canonical opt path must not let a worker authorized for the older recipe
# resolve the newer active receipt. Exercise the native parser without hooks.
older = BASELINE.map do |name, commit|
  history = BrewCooldown::HomebrewAdapter::TapHistory.new(package: PACKAGE.with(name:), log: LOG, now: NOW).refresh
  history.candidate(BrewCooldown::HomebrewAdapter::TapHistoryEntry.new(commit:, published_at: nil)).prepare
end
BrewCooldown::Executor::Postinstall.with_map(BrewCooldown::Executor::ExactMap.new(older)) do
  stage = BrewCooldown::Executor.worker_plan
  code = 'require "cmd/postinstall"; Homebrew::Cmd::Postinstall.new.args.named.to_resolved_formulae'
  output, status = Open3.capture2e(*HOMEBREW_RUBY_EXEC_ARGS, "-I", $LOAD_PATH.join(File::PATH_SEPARATOR),
                                 "-r", (stage/"worker.rb").to_s, "-e", code,
                                 (HOMEBREW_PREFIX/"opt/tart/.brew/tart.rb").to_s)
  raise "Worker accepted another active release: #{output}" unless !status.success? &&
    output.include?("post-install opt recipe no longer selects the planned release")
end
puts "PASS: historical eligible release upgrades, dependency receipts, native hooks and journal cleanup"
