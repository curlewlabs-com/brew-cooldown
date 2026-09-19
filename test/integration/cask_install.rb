# frozen_string_literal: true

require "json"
require "open3"
require_relative "../../lib/brew_cooldown/executor/execution"
require_relative "../../lib/brew_cooldown/executor/cask_map"

abort "Run only in an expendable VM" unless ENV["HOMEBREW_COOLDOWN_DISPOSABLE"] == "1"
BrewCooldown::Executor::Execution.check_homebrew!
mode = ARGV.fetch(0)
records = JSON.parse(File.read(File.join(__dir__, "cask_candidates.json")))
record = records.fetch(mode)
candidate = BrewCooldown::Executor::CaskCandidate.new(record).prepare
cask = candidate.cask
raise "Fixture cask must be unpinned" if cask.pinned?
predecessor = if mode == "upgrade"
  path = cask.installed_caskfile
  raise "Historical baseline missing" unless path

  Cask::CaskLoader.load_from_installed_caskfile(path, api_fallback: false)
end
if predecessor
  raise "Unexpected installed baseline" unless predecessor.version.to_s == records.fetch("baseline").fetch("version")
else
  raise "Baseline requires absent Codex" if cask.installed?
end

# Bind the real installed formula closure. Native cask requirements name
# packages, while the formula map still validates their own receipt edges.
retained = {}
pending = cask.depends_on.formula.dup
until pending.empty?
  name = pending.shift
  next if retained.key?(name)

  opt = HOMEBREW_PREFIX/"opt"/name
  raise "Fixture dependency missing: #{name}" unless opt.exist?

  dependency = BrewCooldown::Executor::Retained.new(Keg.new(opt.realpath))
  retained[name] = dependency
  pending.concat(dependency.runtime_dependencies.map { |entry| entry.fetch("full_name") })
end
formula_map = BrewCooldown::Executor::ExactMap.new(retained.values)
formula_map.activate
map = BrewCooldown::Executor::CaskMap.new(candidate, predecessor:)
map.activate
before = BrewCooldown::Executor::Inventory.capture

# A token alone must resolve to the selected historical object, and another
# cask cannot enter the operation through the native installer or loader.
raise "Selected cask was substituted" unless Cask::CaskLoader.load("codex").equal?(cask)
begin
  Cask::CaskLoader.load("unplanned-cask")
rescue BrewCooldown::Executor::Refused => error
  raise unless error.message.include?("unplanned cask lookup")

  lookup_rejected = true
end
raise "Unplanned cask lookup accepted" unless lookup_rejected
begin
  Cask::Installer.new(Cask::Cask.new("codex"))
rescue BrewCooldown::Executor::Refused => error
  raise unless error.message.include?("unplanned cask object")

  substitution_rejected = true
end
raise "Unplanned cask object accepted" unless substitution_rejected
raise "Guard check mutated inventory" unless BrewCooldown::Executor::Inventory.capture == before

# A real missing active dependency would make Homebrew try to install it.
# Reject that operation before it can bypass the selected formula plan.
dependency_link = HOMEBREW_PREFIX/"opt/ripgrep"
target = dependency_link.readlink
dependency_link.unlink
begin
  Cask::Installer.new(cask, require_sha: true).dependency_installers
rescue BrewCooldown::Executor::Refused => error
  raise unless error.message.include?("dependencies must complete")

  dependency_rejected = true
ensure
  dependency_link.make_symlink(target)
end
raise "Implicit dependency installation accepted" unless dependency_rejected
raise "Dependency check changed inventory" unless BrewCooldown::Executor::Inventory.capture == before

if predecessor
  cask.pin
  begin
    Cask::Installer.new(cask, require_sha: true).prelude
  rescue BrewCooldown::Executor::Refused => error
    raise unless error.message.include?("cask is pinned")

    pin_rejected = true
  ensure
    cask.unpin
  end
  raise "Pinned cask accepted" unless pin_rejected
end

if predecessor
  installer = Cask::Installer.new(cask, upgrade: true, require_sha: true)
  Cask::Upgrade.upgrade_cask(predecessor, cask, binaries: true, force: false, require_sha: true,
                            quit: false, skip_cask_deps: false, verbose: false,
                            download_queue: Homebrew::DownloadQueue.default, new_cask_installer: installer)
else
  Cask::Installer.new(cask, require_sha: true).install
end

receipt = Cask::Tab.from_file(cask.metadata_main_container_path/"INSTALL_RECEIPT.json")
raise "Cask receipt version differs" unless receipt.version == record.fetch("version")
raise "Cask receipt tap differs" unless receipt.tap&.name == "homebrew/cask"
raise "Cask source commit lost" unless receipt.source.fetch("tap_git_head") == record.fetch("commit")
persisted = JSON.parse(receipt.tabfile.read)
raise "Runtime dependency missing from receipt" unless persisted.fetch("runtime_dependencies").fetch("formula").any? { |entry| entry.fetch("full_name") == "ripgrep" }
output, status = Open3.capture2((HOMEBREW_PREFIX/"bin/codex").to_s, "--version")
raise "Historical executable failed: #{output}" unless status.success? && output.include?(record.fetch("version"))
raise "Generated completion missing" unless (HOMEBREW_PREFIX/"share/zsh/site-functions/_codex").exist?
after = BrewCooldown::Executor::Inventory.capture
formula_changes = BrewCooldown::Executor::Inventory.differences(before, after).reject do |change|
  change.fetch("path").start_with?(cask.caskroom_path.to_s + "/")
end
raise "Cask operation changed formula inventory: #{formula_changes}" unless formula_changes.empty?
puts "PASS: historical cask #{mode}, native receipt, executable, completions and retained formula dependencies"
