# frozen_string_literal: true

require "stringio"
require "tmpdir"
require_relative "../../lib/brew_cooldown/upgrade"
require_relative "../../lib/brew_cooldown/explanation"
require_relative "../../lib/brew_cooldown/report"

include BrewCooldown
NOW = Time.iso8601("2026-10-08T06:30:00Z")
FIXTURE = JSON.parse(File.read(File.join(__dir__, "../fixtures/self_managed_casks.json")))

# Installed records are our domain input. Their cask versions and dependency
# edges come from native receipt excerpts, not today's provider recipes.
def record(package, version, dependencies: [], revision: 0, scheme: 0)
  installed = Installed.new(package:, build: Build.new(version:, revision:, rebuild: nil, scheme:), pinned: false)
  HomebrewAdapter::InstalledRecord.new(installed:, dependencies:, compatibility_version: nil,
    retained: nil, receipt: "recorded receipt", identity: Digest::SHA256.hexdigest(package.to_h.to_s))
end

records = FIXTURE.fetch("receipts").to_h do |name, receipt|
  tab = Cask::Tab.from_file_content(JSON.generate(receipt), Pathname("/recorded/#{name}/INSTALL_RECEIPT.json"))
  package = PackageId.new(kind: :cask, tap: tab.source.fetch("tap"), name:)
  [package, record(package, tab.version, dependencies: HomebrewAdapter::InstalledInventory.cask_requirements(tab.runtime_dependencies))]
end
FIXTURE.fetch("formulae").each do |name, metadata|
  package = PackageId.new(kind: :formula, tap: "homebrew/core", name:)
  records[package] = record(package, metadata.fetch("versions").fetch("stable"),
                            revision: metadata.fetch("revision"), scheme: metadata.fetch("version_scheme"))
end
tailscale = records.keys.find { |package| package.name == "tailscale-app" }
gcloud = records.keys.find { |package| package.name == "gcloud-cli" }
current = FIXTURE.fetch("current").dup
inventory = HomebrewAdapter::InventoryResult.new(records:, errors: [], fingerprint: {})
events = []
log = ->(**event) { events << event }

# Only installed state and upstream reads are replaced. Planning, discovery,
# native metadata validation, dependency resolution and upgrade dispatch run.
originals = {
  [HomebrewAdapter::InstalledInventory, :capture] => HomebrewAdapter::InstalledInventory.method(:capture),
  [HomebrewAdapter::CurrentCask, :fetch] => HomebrewAdapter::CurrentCask.method(:fetch),
  [HomebrewAdapter::CurrentFormula, :fetch_all] => HomebrewAdapter::CurrentFormula.method(:fetch_all),
  [HomebrewAdapter::Advisories, :refresh] => HomebrewAdapter::Advisories.method(:refresh),
  [GitHub::API, :open_rest] => GitHub::API.method(:open_rest),
}
begin
  HomebrewAdapter::InstalledInventory.define_singleton_method(:capture) { |log:| inventory }
  HomebrewAdapter::CurrentCask.define_singleton_method(:fetch) do |name, log:|
    HomebrewAdapter::CurrentCask.validate(current.fetch(name), name:)
  end
  HomebrewAdapter::CurrentFormula.define_singleton_method(:fetch_all) do |names, log:|
    names.to_h { |name| [name, HomebrewAdapter::CurrentFormula.validate(FIXTURE.fetch("formulae").fetch(name), name:)] }
  end
  HomebrewAdapter::Advisories.define_singleton_method(:refresh) do |now:, log:|
    HomebrewAdapter::Advisories.new(records: {}, validated_at: now)
  end
  GitHub::API.define_singleton_method(:open_rest) { |url| raise "Unexpected historical source request: #{url}" }

  Dir.mktmpdir("cooldown-self-managed-") do |directory|
    config = Config.new({}, directory: Pathname(directory))
    plan = ->(scope) { Planning.new(config:, scope:, state_directory: directory, log:, now: NOW).call }

    # All-installed runs must stay complete and keep these packages visible
    # without pretending the current API version is the live application.
    result = plan.call({ installed: true })
    raise "Self-managed scope failed assessment: #{result[:errors]}" unless result[:status] == "assessed"
    [gcloud, tailscale].each do |package|
      entry = result.fetch(:scope).find { |row| row[:package] == package.to_h }
      raise "Independent updater silently omitted" unless entry[:status] == :self_managed
      raise "Current version was substituted for native receipt" unless
        entry[:recorded_version] == records.fetch(package).installed.build.version &&
        entry[:recorded_version] != current.fetch(package.name).fetch("version")
      raise "Outside-control boundary hidden" unless entry[:reason].include?("outside cooldown control")
      raise "Self-managed cask gained a candidate" if result[:candidates].any? { |row| row[:package] == package.to_h }
      raise "Unknown cask security coverage disappeared" unless result[:installed_security].any? do |row|
        row[:package] == package.to_h && row[:coverage] == :unsupported_package
      end
      raise "Self-managed cask became an upgrade root" if result[:components].any? { |row| row[:roots].include?(package.to_h) }
    end
    raise "Classification was not logged" unless events.any? { |event| event[:operation] == "classify_cask" }
    json = JSON.parse(JSON.generate(Report.json_value(result)))
    raise "JSON lost the ownership boundary" unless json.fetch("scope").any? { |row| row["status"] == "self_managed" && row["recorded_version"] }
    output = StringIO.new
    Report.print_human(result, output)
    raise "Terminal mislabeled native records as live versions" unless output.string.include?("Homebrew-recorded version: 581.0.0")
    explained = Explanation.call(result, requested: "tailscale-app", installed: records.values.map(&:installed))
    raise "JSON explanation overclaimed a live baseline" unless explained[:explanation][:version_source] == :homebrew_receipt
    output = StringIO.new
    Report.print_explanation(explained, output)
    raise "Focused explanation mislabeled native baseline" unless output.string.include?("Homebrew-recorded version: 1.102.4") &&
      !output.string.include?("Installed: 1.102.4")

    # A self-managed Brewfile root still brings its recorded dependencies into
    # managed scope; the cask remains a consumer in their solver component.
    brewfile = Pathname(directory)/"Brewfile"
    brewfile.write("cask \"gcloud-cli\"\n")
    result = plan.call({ brewfile: })
    dependencies = records.fetch(gcloud).dependencies.map(&:package)
    raise "Recorded dependencies stopped being managed targets" unless dependencies.all? do |package|
      result[:scope].any? { |row| row[:package] == package.to_h && row[:status] == :selected && row[:origin] == :runtime_dependency }
    end
    raise "Retained consumer constraint disappeared" unless result[:components].any? do |component|
      component[:selected].any? { |row| row[:package] == gcloud.to_h && row[:operation] == "retain" &&
        row[:decision][:reason].include?("outside cooldown control") }
    end

    # Self-managed-only upgrades have no executable component. This exercises
    # real dispatch, without substituting a mocked installer for safety proof.
    brewfile.write("cask \"tailscale-app\"\n")
    result = Upgrade.new(config:, scope: { brewfile: }, state_directory: directory, log:, clock: -> { NOW }).call
    raise "Self-managed-only upgrade was not skipped" unless result[:status] == "completed" && result[:execution].empty? &&
      result[:components].empty? && result[:scope].first[:status] == :self_managed

    # A newer recipe cannot revoke the independent updater already present in
    # the installed application. Its installed native declaration still wins.
    original = current.fetch("tailscale-app")
    current["tailscale-app"] = original.merge("auto_updates" => false)
    cask = Cask::Cask.new("tailscale-app") { version "1.102.4"; auto_updates true }
    retained = Struct.new(:cask).new(cask)
    inventory = inventory.with(records: records.merge(tailscale => records.fetch(tailscale).with(retained:)))
    result = plan.call({ brewfile: })
    raise "Current recipe revoked installed independent ownership" unless result[:status] == "assessed" &&
      result[:scope].first[:status] == :self_managed && result[:candidates].empty?
    inventory = inventory.with(records:)
    current["tailscale-app"] = original

    # A valid self-update flag cannot erase a withdrawal or an evidence error.
    original = current.fetch("tailscale-app")
    [original.reject { |key, _| key == "auto_updates" }, original.merge("auto_updates" => "true"),
     original.merge("disabled" => true, "disable_reason" => "security withdrawal")].each do |invalid|
      current["tailscale-app"] = invalid
      result = plan.call({ brewfile: })
      raise "Invalid provider evidence silently became self-managed" unless result[:status] == "incomplete" &&
        result[:errors].any? && result[:scope].none? { |row| row[:status] == :self_managed }
    end
    current["tailscale-app"] = original
    inventory = inventory.with(errors: [{ operation: "read_installed_cask", package: "unreadable", error: "receipt unreadable" }])
    result = Upgrade.new(config:, scope: { brewfile: }, state_directory: directory, log:, clock: -> { NOW }).call
    raise "Self-managed classification erased unreadable inventory" unless result[:status] == "incomplete" && result[:execution].empty?
    inventory = inventory.with(errors: [])

    # A native pin precedes classification even when provider metadata is bad.
    held = records.fetch(tailscale).with(installed: records.fetch(tailscale).installed.with(pinned: true))
    inventory = inventory.with(records: records.merge(tailscale => held))
    current["tailscale-app"] = {}
    result = plan.call({ brewfile: })
    raise "Pin required upstream discovery or lost precedence" unless result[:status] == "assessed" && result[:scope].first[:status] == :pinned
    explained = Explanation.call(result, requested: "tailscale-app", installed: [held.installed])
    output = StringIO.new
    Report.print_explanation(explained, output)
    raise "Pin certified a live application version" unless output.string.include?("Homebrew-recorded version: 1.102.4")
    inventory = inventory.with(records:)
    current["tailscale-app"] = original

    # A managed cask becoming self-updating invalidates an earlier selection
    # before revalidation reaches history or the vendor download.
    candidate = Struct.new(:cask).new(Struct.new(:version).new(Version.new("1.102.4")))
    revalidation = HomebrewAdapter::Revalidation.new(config:, inventory:, prepared: {}, state_directory: directory, log:, clock: -> { NOW })
    begin
      revalidation.send(:cask_release, tailscale, candidate, verify_payload: false)
    rescue HomebrewAdapter::RegistryError => error
      raise unless error.message.include?("outside cooldown control")
      refused = true
    end
    raise "Pre-install transition to independent ownership accepted" unless refused
  end
ensure
  originals.each { |(owner, name), method| owner.define_singleton_method(name, method) }
end

# Self-managed scope needs identity and capability evidence, not execution
# provenance for a historical artifact it will never select.
adapter = HomebrewAdapter::CurrentCask
minimal = FIXTURE.fetch("current").fetch("tailscale-app").slice("token", "tap", "disabled", "auto_updates").merge("version" => "latest")
raise "Self-managed latest demanded historical authority" unless adapter.validate(minimal, name: "tailscale-app") == minimal
managed = FIXTURE.fetch("current").fetch("codex")
raise "Native unset stanza rejected" unless adapter.validate(managed, name: "codex") == managed
raise "Explicit false stanza rejected" unless adapter.validate(managed.merge("auto_updates" => false), name: "codex")
begin
  adapter.validate(managed.reject { |key, _| key == "tap_git_head" }, name: "codex")
rescue HomebrewAdapter::RegistryError
  source_refused = true
end
raise "Managed cask lost immutable source requirement" unless source_refused
puts "PASS: self-managed scope, recorded versions, managed dependencies, upgrade skipping and fail-closed evidence"
