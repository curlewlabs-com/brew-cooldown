# frozen_string_literal: true

require "open3"
require "tempfile"
require_relative "../../lib/brew_cooldown/upgrade"
require_relative "../../lib/brew_cooldown/recovery"
require_relative "../../lib/brew_cooldown/report"

abort "Run only in an expendable Apple Silicon VM" unless ENV["HOMEBREW_COOLDOWN_DISPOSABLE"] == "1"
BrewCooldown::Executor::Execution.check_homebrew!
NAME, PHASE = ARGV
raise "Unknown cask" unless %w[gcloud-cli tailscale-app].include?(NAME)
STATE = Pathname(ENV.fetch("HOMEBREW_COOLDOWN_TEST_STATE"))
RECORDS = JSON.parse(File.read(File.join(__dir__, "native_cask_candidates.json"))).fetch(NAME)
LOG = ->(**event) { warn JSON.generate(BrewCooldown::Report.json_value(event)) }
# Fixed UTC and local dates differ. These delays retain an eligible historical
# SDK/app while the successor releases remain cooling on this evaluation date.
NOW = Time.iso8601("2026-10-08T06:30:00Z")
CONFIG = BrewCooldown::Config.new({ "cooldown" => { "patch_days" => 40, "major_days" => 30 } }, directory: STATE)
PACKAGE = BrewCooldown::PackageId.new(kind: :cask, tap: "homebrew/cask", name: NAME)

def capture_plan
  planning = BrewCooldown::Planning.new(config: CONFIG, scope: { installed: true }, now: NOW, log: LOG, state_directory: STATE)
  plan = planning.call
  puts JSON.pretty_generate(BrewCooldown::Report.json_value(plan))
  raise "All-installed native cask assessment failed: #{plan[:errors]}" unless plan.fetch(:status) == "assessed"
  resolution = planning.resolutions.find { |entry| entry.selected.key?(PACKAGE) }
  selected = resolution&.selected&.fetch(PACKAGE)
  expected = NAME == "gcloud-cli" ? "583.0.0" : "1.102.3"
  raise "Historical cask not selected" unless selected && !selected.retained && selected.release.build.version == expected
  raise "Cask cooldown was not applied" unless selected.decision.status == :eligible && selected.decision.eligible_at <= NOW
  raise "Newer cooling candidate disappeared" unless plan.fetch(:candidates).any? do |row|
    row.fetch(:package) == PACKAGE.to_h && row.fetch(:decision).fetch(:status) == :cooldown
  end
  [planning, resolution]
end

def executor(candidate, predecessor: nil)
  retained = {}
  pending = candidate.cask.depends_on.formula.dup
  until pending.empty?
    name = pending.shift
    next if retained.key?(name)

    dependency = BrewCooldown::Executor::Retained.new(Keg.new((HOMEBREW_PREFIX/"opt"/name).realpath))
    retained[name] = dependency
    pending.concat(dependency.runtime_dependencies.map { |entry| entry.fetch("full_name") })
  end
  map = BrewCooldown::Executor::ExactMap.new(retained.values)
  map.activate
  BrewCooldown::Executor::CaskMap.new(candidate, predecessor:).activate
  operation = BrewCooldown::Executor::CaskOperation.new(candidate, predecessor:)
  [BrewCooldown::Executor::Execution.new(map, state_directory: STATE, casks: [operation]), operation]
end

def verify_payload
  retained = BrewCooldown::Executor::CaskRetained.new(NAME)
  if NAME == "gcloud-cli"
    BrewCooldown::Executor::NativeCaskContract.with_installer_environment(retained.cask) do
      output, status = Open3.capture2e((HOMEBREW_PREFIX/"bin/gcloud").to_s, "version", "--format=json")
      raise "Historical gcloud does not run: #{output}" unless status.success? && JSON.parse(output).fetch("Google Cloud SDK") == retained.cask.version.to_s
    end
    root = HOMEBREW_PREFIX/"share/google-cloud-sdk"
    alpha = JSON.parse((root/".install/alpha.snapshot.json").read)
    raise "Optional SDK component advanced independently" unless alpha.fetch("version") == retained.cask.version.to_s
  else
    output, status = Open3.capture2e("/Applications/Tailscale.app/Contents/MacOS/Tailscale", "version")
    raise "Historical Tailscale does not run: #{output}" unless status.success? && output.lines.first.strip == retained.cask.version.to_s
  end
  retained
end

case PHASE
when "baseline"
  candidate = BrewCooldown::Executor::CaskCandidate.new(RECORDS.fetch("baseline")).prepare
  raise "Baseline already installed" if candidate.cask.installed?
  execution, = executor(candidate)
  result = execution.apply(expected_inventory: BrewCooldown::Executor::Inventory.capture)
  raise "Historical native baseline failed: #{result}" unless result.fetch("status") == "completed"
  if NAME == "gcloud-cli"
    # The SDK installer promises to preserve optional components. Exercise a
    # real component so qualification cannot pass only on a clean SDK archive.
    BrewCooldown::Executor::NativeCaskContract.with_installer_environment(candidate.cask) do
      output, status = Open3.capture2e((HOMEBREW_PREFIX/"bin/gcloud").to_s, "components", "install", "alpha", "--quiet")
      puts output
      raise "Optional SDK component installation failed" unless status.success?
    end
  end
when "verify"
  verify_payload
when "assessment"
  before = BrewCooldown::Executor::Inventory.capture
  capture_plan
  raise "Planning mutated native state" unless BrewCooldown::Executor::Inventory.capture == before
  cask = BrewCooldown::Executor::CaskRetained.new(NAME).cask
  cask.pin
  begin
    plan = BrewCooldown::Planning.new(config: CONFIG, scope: { installed: true }, now: NOW, log: LOG, state_directory: STATE).call
    raise "Pinned cask was omitted" unless plan.fetch(:scope).any? { |row| row[:package] == PACKAGE.to_h && row[:status] == :pinned }
    raise "Pinned cask selected" if plan.fetch(:components).flat_map { |row| row.fetch(:selected) }.any? do |row|
      row[:package] == PACKAGE.to_h && row[:operation] == "upgrade"
    end
  ensure
    cask.unpin
  end
  raise "Pin test changed installed state" unless BrewCooldown::Executor::Inventory.capture == before
when "upgrade"
  planning, resolution = capture_plan
  selected = planning.discovery.prepared.fetch(resolution.selected.fetch(PACKAGE).release.identity)
  previous = planning.inventory.records.fetch(PACKAGE).retained.cask
  operation = BrewCooldown::Executor::CaskOperation.new(selected, predecessor: previous)
  before = BrewCooldown::Executor::Inventory.capture
  result = BrewCooldown::Upgrade.new(config: CONFIG, scope: { installed: true }, state_directory: STATE, log: LOG, clock: -> { NOW }).call
  puts JSON.pretty_generate(BrewCooldown::Report.json_value(result))
  raise "All-installed upgrade failed" unless result.fetch(:status) == "completed"
  path = selected.cask.metadata_main_container_path/"INSTALL_RECEIPT.json"
  receipt = Cask::Tab.from_file_content(path.read, path)
  raise "Installed version differs from historical selection" unless receipt.version == selected.cask.version.to_s
  raise "Historical recipe provenance lost" unless receipt.source.fetch("tap_git_head") == selected.record.fetch("commit")
  BrewCooldown::Executor::NativeCaskContract.verify_installed!(selected.cask)
  changes = BrewCooldown::Executor::Inventory.differences(before, BrewCooldown::Executor::Inventory.capture)
  raise "Native cask mutated unplanned inventory" unless changes.any? && changes.all? { |row| operation.owns_path?(row.fetch("path")) }
  raise "Completed journal retained" unless BrewCooldown::Journals.new(STATE).pending.empty?
when "drift"
  candidate = BrewCooldown::Executor::CaskCandidate.new(RECORDS.fetch("upgrade")).prepare
  previous = BrewCooldown::Executor::CaskRetained.new(NAME).cask
  execution, = executor(candidate, predecessor: previous)
  before = BrewCooldown::Executor::Inventory.capture
  path = BrewCooldown::Executor::NativeCaskContract.files(NAME).first
  original = path.binread
  begin
    # Simulate an external updater changing the payload without a new Tab.
    # Inventory must reject the change before uninstalling the predecessor.
    if NAME == "gcloud-cli"
      path.write("999.0.0\n")
    else
      output, status = Open3.capture2e("sudo", "/usr/bin/plutil", "-replace", "CFBundleShortVersionString", "-string", "999.0.0", path.to_s)
      raise "Cannot mutate VM payload: #{output}" unless status.success?
    end
    changed = BrewCooldown::Executor::Inventory.capture
    result = execution.apply(expected_inventory: before)
    raise "External update not reported as drift" unless result.fetch("status") == "drift"
    raise "Drift executed package mutation" unless changed == BrewCooldown::Executor::Inventory.capture
    begin
      BrewCooldown::Executor::CaskRetained.new(NAME)
    rescue BrewCooldown::Executor::Refused => error
      raise unless error.message.include?("differs from Homebrew receipt")
      rejected = true
    end
    raise "Externally updated payload accepted as receipt baseline" unless rejected
  ensure
    if NAME == "gcloud-cli"
      path.binwrite(original)
    else
      Tempfile.create("cooldown-native-plist") do |file|
        file.binmode
        file.write(original)
        file.flush
        output, status = Open3.capture2e("sudo", "/bin/cp", file.path, path.to_s)
        raise "Cannot restore VM payload: #{output}" unless status.success?
      end
    end
  end
when "crash_check"
  boundary = ARGV.fetch(2)
  raise "Unknown interruption boundary" unless %w[started native completed].include?(boundary)
  output, status = Open3.capture2e(HOMEBREW_BREW_FILE.to_s, "ruby", "--", __FILE__, NAME, "interrupt", boundary)
  puts output
  raise "Expected SIGKILL: #{status}" unless status.signaled? && status.termsig == Signal.list.fetch("KILL")
  before = BrewCooldown::Executor::Inventory.capture
  report = BrewCooldown::Recovery.new(state_directory: STATE, log: LOG).call
  operation = report.fetch(:operations).find { |entry| entry.fetch("name") == NAME }
  expected = boundary == "completed" ? "completed" : "unconfirmed"
  raise "Wrong interruption state: #{report}" unless operation && operation.fetch("status") == expected
  raise "Recovery changed native state" unless before == BrewCooldown::Executor::Inventory.capture
  raise "Cask recovery missing" unless operation.fetch("recovery").all? { |entry| entry.fetch("command").include?("--cask") }
  if boundary == "native"
    begin
      BrewCooldown::Executor::CaskRetained.new(NAME)
    rescue BrewCooldown::Executor::Refused
      unconfirmed = true
    end
    raise "Partial native install became a confirmed baseline" unless unconfirmed
  end
when "interrupt"
  boundary = ARGV.fetch(2)
  candidate = BrewCooldown::Executor::CaskCandidate.new(RECORDS.fetch("upgrade")).prepare
  previous = BrewCooldown::Executor::CaskRetained.new(NAME).cask
  execution, = executor(candidate, predecessor: previous)
  if boundary == "native"
    artifact = NAME == "gcloud-cli" ? Cask::Artifact::PreflightSteps : Cask::Artifact::Pkg
    artifact.prepend(Module.new do
      define_method(:install_phase) do |**options|
        super(**options)
        Process.kill("KILL", Process.pid)
      end
    end)
  end
  execution.apply(expected_inventory: BrewCooldown::Executor::Inventory.capture) do |name, status|
    Process.kill("KILL", Process.pid) if name == NAME && status == boundary
  end
  raise "Interruption boundary was not reached"
when "repair_forward"
  report = BrewCooldown::Recovery.new(state_directory: STATE, log: LOG).call
  operation = report.fetch(:operations).find { |entry| entry.fetch("name") == NAME }
  command = operation.fetch("recovery").find { |row| row.fetch("purpose").start_with?("Repair forward") }.fetch("command")
  output, status = Open3.capture2e(*Shellwords.split(command))
  puts output
  raise "Printed native forward repair failed" unless status.success?
  verify_payload
  raise "Repair silently acknowledged journal" if BrewCooldown::Journals.new(STATE).pending.empty?
when "accept"
  recovery = BrewCooldown::Recovery.new(state_directory: STATE, log: LOG)
  before = BrewCooldown::Executor::Inventory.capture
  report = recovery.call
  result = recovery.call(accept_current: report.fetch(:accept_current).fetch("digest"))
  raise "Explicit recovery acceptance failed" unless result.fetch(:status) == "accepted_current"
  raise "Acceptance mutated packages" unless before == BrewCooldown::Executor::Inventory.capture
else
  raise "Unknown phase #{PHASE}"
end
puts "PASS: #{NAME} #{PHASE}"
