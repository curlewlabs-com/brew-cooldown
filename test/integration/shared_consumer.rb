# frozen_string_literal: true

require "open3"

abort "Run only in an expendable VM" unless ENV["HOMEBREW_COOLDOWN_DISPOSABLE"] == "1"
abort "This proof requires Apple Silicon Tahoe at /opt/homebrew" unless
  HOMEBREW_PREFIX.to_s == "/opt/homebrew" && Utils::Bottles.tag.to_sym == :arm64_tahoe

require_relative "../../lib/brew_cooldown/validated_homebrew"
expected = BrewCooldown::VALIDATED_HOMEBREW_COMMIT
commit, status = Open3.capture2("git", "-C", HOMEBREW_REPOSITORY.to_s, "rev-parse", "HEAD")
abort "Uninspected Homebrew checkout" unless status.success? && commit.strip == expected
changes, status = Open3.capture2("git", "-C", HOMEBREW_REPOSITORY.to_s, "status", "--porcelain", "--untracked-files=no")
abort "Modified Homebrew checkout" unless status.success? && changes.empty?

require_relative "../../prototype/postinstall"

phase = ARGV.fetch(0)
all_records = JSON.parse(File.read(File.join(__dir__, "shared_candidates.json")))
candidates = all_records.fetch(phase).map do |record|
  BrewCooldown::Prototype::Candidate.new(record).prepare(allow_hooks: true)
end
consumer = nil
receipt = nil
if phase == "baseline"
  raise "Baseline requires fish and PCRE2 absent" unless candidates.all? { |candidate| candidate.formula.installed_kegs.empty? }
else
  consumer = BrewCooldown::Prototype::Retained.new(Keg.new(HOMEBREW_CELLAR/"fish/4.7.1"))
  receipt = (consumer.keg/"INSTALL_RECEIPT.json").binread
  if phase == "insufficient_evidence"
    before = (HOMEBREW_PREFIX/"opt/pcre2").readlink
    begin
      consumer.check_candidate!(candidates.fetch(0))
    rescue BrewCooldown::Prototype::Refused => error
      raise "Wrong refusal: #{error}" unless error.message.include?("no compatibility evidence")
      raise "Refusal changed consumer" unless (consumer.keg/"INSTALL_RECEIPT.json").binread == receipt
      raise "Refusal changed dependency" unless (HOMEBREW_PREFIX/"opt/pcre2").readlink == before
      puts "PASS: missing compatibility evidence reported before mutation: #{error}"
      exit
    end
    raise "Accepted a dependency without consumer compatibility evidence"
  end
  consumer.check_candidate!(candidates.fetch(0))
end

map = BrewCooldown::Prototype::ExactMap.new(candidates + [consumer].compact)
map.activate
if consumer
  begin
    FormulaInstaller.new(consumer.formula)
  rescue BrewCooldown::Prototype::Refused => error
    raise "Wrong retained-consumer refusal" unless error.message.include?("retained consumer")
    puts "PASS: unplanned consumer installation rejected"
  else
    raise "Accepted an out-of-scope consumer installation"
  end
end

root = map.resolve(phase == "baseline" ? "fish" : "pcre2")
BrewCooldown::Prototype::Postinstall.with_map(map) do
  installer = FormulaInstaller.new(root, installed_on_request: true)
  installer.prelude
  installer.fetch
  Homebrew::Install.install_formula(installer, upgrade: phase == "upgrade")
end
raise "Homebrew reported installation failure" if Homebrew.failed?
raise "Changed retained receipt" if consumer && (consumer.keg/"INSTALL_RECEIPT.json").binread != receipt
raise "Changed retained opt link" unless (HOMEBREW_PREFIX/"opt/fish").realpath == HOMEBREW_CELLAR/"fish/4.7.1"
expected_version = phase == "baseline" ? "10.47_1" : "10.48"
raise "Wrong dependency version" unless (HOMEBREW_PREFIX/"opt/pcre2").realpath == HOMEBREW_CELLAR/"pcre2"/expected_version

consumer ||= BrewCooldown::Prototype::Retained.new(Keg.new(HOMEBREW_CELLAR/"fish/4.7.1"))
consumer.check_linkage!
output, status = Open3.capture2((HOMEBREW_PREFIX/"opt/fish/bin/fish").to_s, "-c", "string match -r 'a(?=b)' ab")
raise "Shared consumer runtime failed" unless status.success? && output == "a\n"
puts "PASS #{phase}: fish retained with working PCRE2 #{expected_version}"
