# frozen_string_literal: true

require "open3"

abort "Run only in an expendable VM; see docs/installer-proof.md" unless ENV["HOMEBREW_COOLDOWN_DISPOSABLE"] == "1"
abort "This proof requires Apple Silicon Tahoe at /opt/homebrew" unless
  HOMEBREW_PREFIX.to_s == "/opt/homebrew" && Utils::Bottles.tag.to_sym == :arm64_tahoe

require_relative "../../lib/brew_cooldown/validated_homebrew"
expected_commit = BrewCooldown::VALIDATED_HOMEBREW_COMMIT
commit, status = Open3.capture2("git", "-C", HOMEBREW_REPOSITORY.to_s, "rev-parse", "HEAD")
abort "Uninspected Homebrew checkout" unless status.success? && commit.strip == expected_commit
changes, status = Open3.capture2("git", "-C", HOMEBREW_REPOSITORY.to_s, "status", "--porcelain", "--untracked-files=no")
abort "Modified Homebrew checkout" unless status.success? && changes.empty?

require_relative "../../lib/brew_cooldown/executor/postinstall"

def assert(condition, message)
  raise message unless condition
end

def inventory
  receipts = HOMEBREW_CELLAR.glob("*/*/INSTALL_RECEIPT.json").to_h do |path|
    [path.to_s, Digest::SHA256.file(path).hexdigest]
  end
  links = (HOMEBREW_PREFIX/"opt").children.select(&:symlink?).to_h do |path|
    [path.to_s, path.readlink.to_s]
  end
  [receipts, links]
end

def refuses(description)
  before = inventory
  begin
    yield
  rescue BrewCooldown::Executor::Refused => error
    assert(inventory == before, "#{description} mutated installed packages")
    puts "Refused #{description} before mutation: #{error.message}"
    return
  end
  raise "Accepted #{description}"
end

phase = ARGV.fetch(0)
records = JSON.parse(File.read(File.join(__dir__, "candidates.json"))).fetch(phase)
expected_kegs = records.to_h do |record|
  [record.fetch("name"), HOMEBREW_CELLAR/record.fetch("name")/record.fetch("version")]
end
expected_links = records.flat_map do |record|
  [record.fetch("name"), *record.fetch("opt_aliases")].map do |name|
    [(HOMEBREW_PREFIX/"opt"/name).to_s, expected_kegs.fetch(record.fetch("name"))]
  end
end.to_h
current = %w[pcre2 ripgrep].to_h { |name| [name, Formulary.factory(name)] }
candidates = records.map { |record| BrewCooldown::Executor::Candidate.new(record).prepare }
candidates.each do |candidate|
  formula = candidate.formula
  assert(current.fetch(formula.name).pkg_version > formula.pkg_version, "Expected newer current #{formula.name}")
  if phase == "baseline"
    assert(formula.installed_kegs.empty?, "Baseline requires #{formula.name} absent")
  else
    assert(formula.opt_prefix.symlink?, "Missing baseline #{formula.name}")
    assert(Keg.new(formula.opt_prefix.realpath).version < formula.pkg_version, "Not an upgrade")
  end
end

refuses("incomplete candidate graph") do
  root_only = candidates.select { |candidate| candidate.formula.name == "ripgrep" }
  BrewCooldown::Executor::ExactMap.new(root_only).activate
end

map = BrewCooldown::Executor::ExactMap.new(candidates)
map.activate

# These probes exercise the real Homebrew entrypoints, so a missed guard can
# perform a real unwanted operation and fails the inventory comparison.
refuses("unplanned dependency") { Dependency.new("zlib").to_formula }
refuses("HEAD recipe substitution") { Formulary.factory("pcre2", :head) }
refuses("current formula substitution") { FormulaInstaller.new(current.fetch("pcre2")).prelude }
refuses("source fallback") do
  FormulaInstaller.new(map.resolve("pcre2"), build_from_source_formulae: ["pcre2"]).prelude
end
refuses("disabled dependency checks") do
  FormulaInstaller.new(map.resolve("ripgrep"), ignore_deps: true).prelude
end

before = inventory
root = map.resolve("ripgrep")
installer = FormulaInstaller.new(root, installed_on_request: true)
# Match the adapter's ordinary install environment: developer source-cycle
# diagnostics otherwise resolve build-only recipes even for these bottles.
with_env(HOMEBREW_DEVELOPER: nil) do
  BrewCooldown::Executor::Postinstall.with_map(map) do
    installer.prelude
    installer.fetch
    Homebrew::Install.install_formula(installer, upgrade: phase == "upgrade")
  end
end
assert(!Homebrew.failed?, "Homebrew reported installation failure")

candidates.each do |candidate|
  formula = candidate.formula
  expected_keg = expected_kegs.fetch(formula.name)
  assert(formula.opt_prefix.realpath == expected_keg, "Wrong opt link for #{formula.name}")
  tab = Tab.for_keg(expected_keg)
  assert(tab.poured_from_bottle, "Source build for #{formula.name}")
  assert(tab.tap == "homebrew/core", "Lost canonical tap for #{formula.name}")
  assert(expected_keg.join(".brew", "#{formula.name}.rb").file?, "Missing embedded recipe")
end

# A real PCRE expression forces the dynamically linked dependency to execute.
output, status = Open3.capture2((root.opt_bin/"rg").to_s, "--pcre2", "a(?=b)", stdin_data: "ab\n")
assert(status.success? && output == "ab\n", "Historical application or its dependency failed")
version, status = Open3.capture2((root.opt_bin/"rg").to_s, "--version")
assert(status.success? && version.include?("ripgrep #{root.version}"), "Wrong application version")
after = inventory
expected_links.each do |path, keg|
  assert(Pathname(path).realpath == keg, "Wrong canonical or alias link: #{path}")
end
before.each_with_index do |entries, index|
  entries.each do |path, value|
    next if expected_links.key?(path)
    next if candidates.any? { |candidate| path.start_with?(candidate.formula.rack.to_s + "/") }

    assert(after.fetch(index)[path] == value, "Changed out-of-scope package: #{path}")
  end
end
expected_receipts = expected_kegs.values.map { |keg| (keg/"INSTALL_RECEIPT.json").to_s }
unexpected_receipts = after.fetch(0).keys - before.fetch(0).keys - expected_receipts
assert(unexpected_receipts.empty?, "Installed unplanned packages: #{unexpected_receipts}")
unexpected_links = after.fetch(1).keys - before.fetch(1).keys - expected_links.keys
assert(unexpected_links.empty?, "Created unplanned opt links: #{unexpected_links}")
puts "PASS #{phase}: exact historical bottles, canonical receipts and links, working runtime"
