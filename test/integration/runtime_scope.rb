# frozen_string_literal: true

require "open3"
require "tmpdir"
require_relative "../../lib/brew_cooldown/homebrew/installed_inventory"

abort "Run only in an expendable VM with historical Codex and formula fixtures" unless ENV["HOMEBREW_COOLDOWN_DISPOSABLE"] == "1"
cask = BrewCooldown::Executor::CaskRetained.new("codex").cask
raise "Expected historical cask with a ripgrep dependency" unless cask.version.to_s == "0.144.5"
raise "Fixture cask is already pinned" if cask.pinned?
baseline = { "pcre2" => "10.46", "ripgrep" => "15.0.0" }
baseline.each do |name, version|
  raise "Missing baseline #{name}" unless (HOMEBREW_CELLAR/name/version).directory?
  raise "Fixture dependency is already pinned" if (HOMEBREW_PINNED_KEGS/name).symlink?
end
raise "Fixture unlink failed" unless system(HOMEBREW_BREW_FILE.to_s, "unlink", "--formula", *baseline.keys)
baseline.each do |name, version|
  Keg.new(HOMEBREW_CELLAR/name/version).link
  (HOMEBREW_CELLAR/name).children.select(&:directory?).each do |path|
    Keg.new(path).uninstall(raise_failures: true) unless path.basename.to_s == version
  end
end
receipt_path = cask.metadata_main_container_path/"INSTALL_RECEIPT.json"
receipt = receipt_path.binread
cask.pin
begin
  Dir.mktmpdir("cooldown-runtime-scope-") do |directory|
    brewfile = Pathname(directory)/"Brewfile"
    brewfile.write("cask \"codex\"\n")
    state = Pathname(directory)/"state"
    with_env(XDG_STATE_HOME: state.to_s) do
      launcher = File.expand_path("../../bin/brew-cooldown", __dir__)
      stdout, stderr, status = Open3.capture3(launcher, "upgrade", "--brewfile", brewfile.to_s, "--json")
      warn stderr
      result = JSON.parse(stdout)
      puts JSON.pretty_generate(result)
      raise "Runtime closure upgrade did not complete" unless status.success? && result.fetch("status") == "completed"
      added = result.fetch("scope").select { |entry| entry["origin"] == "runtime_dependency" }
      raise "Runtime closure was not visible" unless added.map { |entry| entry.fetch("package").fetch("name") }.sort == baseline.keys.sort
      raise "Dependency provenance was lost" unless added.all? { |entry| entry.fetch("required_by").any? }
      raise "Pinned root was not reported" unless result.fetch("scope").any? { |entry| entry["requested"] == "codex" && entry["status"] == "pinned" }
      # A pinned root must not freeze its independently eligible dependencies,
      # and dependency progress must not become permission to upgrade that root.
      operations = result.fetch("execution").flat_map { |entry| entry.fetch("operations") }
      raise "Pinned cask was changed" unless receipt_path.binread == receipt && cask.pinned? && operations.all? { |entry| entry.fetch("kind") == "formula" }
      baseline.each do |name, version|
        raise "Runtime dependency did not advance: #{name}" unless Keg.new((HOMEBREW_PREFIX/"opt"/name).realpath).version > PkgVersion.parse(version)
      end
      output, check = Open3.capture2((HOMEBREW_PREFIX/"bin/codex").to_s, "--version")
      raise "Retained cask failed" unless check.success? && output.include?("0.144.5")
      output, check = Open3.capture2((HOMEBREW_PREFIX/"opt/ripgrep/bin/rg").to_s, "--pcre2", "a(?=b)", stdin_data: "ab\n")
      raise "Upgraded dependency runtime failed" unless check.success? && output == "ab\n"
      raise "Completed runtime journal remained" unless state.glob("**/active.json").empty?
      # A repeated scheduled assessment must preserve uncertainty about native
      # bottle identity without inventing an upgrade failure for this version.
      stdout, stderr, status = Open3.capture3(launcher, "plan", "--brewfile", brewfile.to_s, "--json")
      warn stderr
      repeated = JSON.parse(stdout)
      raise "Completed native versions failed reassessment" unless status.success? && repeated.fetch("status") == "assessed"
      repackaged = result.fetch("components").flat_map { |entry| entry.fetch("selected") }
                         .select { |entry| entry.fetch("operation") == "upgrade" && entry.fetch("build").fetch("rebuild").positive? }
      repackaged.each do |entry|
        raise "Installed rebuild uncertainty disappeared" unless repeated.fetch("diagnostics").any? do |diagnostic|
          diagnostic.fetch("package") == entry.fetch("package") && diagnostic.fetch("status") == "unknown_installed_build"
        end
      end
    end
  end
ensure
  cask.unpin
end
puts "PASS: pinned Brewfile root retained while installed runtime dependencies upgrade independently"
