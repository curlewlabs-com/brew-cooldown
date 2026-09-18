# frozen_string_literal: true

require "open3"

abort "Run only in an expendable VM" unless ENV["HOMEBREW_COOLDOWN_DISPOSABLE"] == "1"
abort "This proof requires Apple Silicon Tahoe at /opt/homebrew" unless
  HOMEBREW_PREFIX.to_s == "/opt/homebrew" && Utils::Bottles.tag.to_sym == :arm64_tahoe

expected = "edb70f031e4170c780799633a1226ff73e1077f4"
commit, status = Open3.capture2("git", "-C", HOMEBREW_REPOSITORY.to_s, "rev-parse", "HEAD")
abort "Uninspected Homebrew checkout" unless status.success? && commit.strip == expected
changes, status = Open3.capture2("git", "-C", HOMEBREW_REPOSITORY.to_s, "status", "--porcelain", "--untracked-files=no")
abort "Modified Homebrew checkout" unless status.success? && changes.empty?

require_relative "../../prototype/postinstall"

records = JSON.parse(File.read(File.join(__dir__, "hook_candidates.json")))
candidates = records.map { |record| BrewCooldown::Prototype::Candidate.new(record).prepare(allow_hooks: true) }
candidates.each do |candidate|
  raise "This experiment requires #{candidate.formula.name} absent" unless candidate.formula.installed_kegs.empty?
end

map = BrewCooldown::Prototype::ExactMap.new(candidates)
map.activate
fish = map.resolve("fish")
raise "Expected a real Ruby post-install hook" unless fish.post_install_defined?
hook_directories = %w[vendor_functions.d vendor_completions.d vendor_conf.d]

# These paths must originate in the hook, not make the assertion pass just
# because the bottle already contained them.
fish_candidate = candidates.find { |candidate| candidate.formula.name == "fish" }
fish_candidate.bottle.with_verified_snapshot(fish_candidate.bottle.cached_download) do |snapshot|
  members, status = Open3.capture2("/usr/bin/tar", "-tf", snapshot.to_s)
  raise "Could not inspect fish bottle" unless status.success?
  if members.lines.any? { |line| hook_directories.any? { |directory| line.include?("/#{directory}") } }
    raise "Hook outputs already in bottle"
  end
end

BrewCooldown::Prototype::Postinstall.with_map(map) do
  installer = FormulaInstaller.new(fish, installed_on_request: true)
  installer.prelude
  installer.fetch
  Homebrew::Install.install_formula(installer, upgrade: false)
end
raise "Homebrew reported hook failure" if Homebrew.failed?

hook_directories.each do |directory|
  raise "Hook did not create #{directory}" unless (fish.pkgshare/directory).directory?
end
output, status = Open3.capture2((fish.opt_bin/"fish").to_s, "-c", "string match -r 'a(?=b)' ab")
raise "Fish or its shared library failed" unless status.success? && output == "a\n"
raise "Wrong hook recipe version" unless fish.opt_prefix.realpath == HOMEBREW_CELLAR/"fish/4.0.6"
puts "PASS: native sandboxed historical hook and PCRE-backed fish execution"
