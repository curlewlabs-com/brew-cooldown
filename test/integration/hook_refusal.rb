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

require_relative "../../lib/brew_cooldown/executor/postinstall"

records = JSON.parse(File.read(File.join(__dir__, "hook_candidates.json")))
candidates = records.map { |record| BrewCooldown::Executor::Candidate.new(record).prepare(allow_hooks: true) }
map = BrewCooldown::Executor::ExactMap.new(candidates)
map.activate
fish = map.resolve("fish")
raise "Run hook_install.rb first" unless fish.opt_prefix.realpath == HOMEBREW_CELLAR/"fish/4.0.6"

def inventory
  receipts = HOMEBREW_CELLAR.glob("*/*/INSTALL_RECEIPT.json").to_h do |path|
    [path.to_s, Digest::SHA256.file(path).hexdigest]
  end
  links = (HOMEBREW_PREFIX/"opt").children.select(&:symlink?).to_h do |path|
    [path.to_s, path.readlink.to_s]
  end
  [receipts, links]
end

probes = {
  "unplanned lookup" => ['Formula["zlib"]', "BrewCooldownWorker::Refused", "unplanned post-install lookup"],
  "recursive installer" => ['FormulaInstaller.new(Formula["fish"])', "BrewCooldownWorker::Refused", "package installation"],
  "recursive brew" => ['system HOMEBREW_BREW_FILE.to_s, "--version"', "BuildError", "Failed executing"],
  "worker handoff write" => ['File.write(ENV.fetch("HOMEBREW_COOLDOWN_WORKER_PLAN"), "[]")', "Errno::EPERM", "Operation not permitted"]
}

probes.each do |description, (body, error_class, message)|
  owns_report = false
  before = inventory
  report = fish.logs/"cooldown-refusal.json"
  raise "Probe report already exists" if report.exist?
  owns_report = true
  BrewCooldown::Executor::Postinstall.with_map(map) do
    path = BrewCooldown::Executor.worker_plan/"recipes.json"
    worker_records = JSON.parse(path.read)
    record = worker_records.find { |entry| entry.fetch("name") == "fish" }
    # Deliberately hostile hook fixtures exercise the real native worker.
    # They are never installation candidates or claimed to be signed recipes.
    record["recipe"] += <<~RUBY

      class Fish
        def post_install
          #{body}
        rescue StandardError => error
          (logs/"cooldown-refusal.json").write(JSON.generate(class: error.class.name, message: error.message))
          raise
        end
      end
    RUBY
    record["recipe_sha256"] = Digest::SHA256.hexdigest(record.fetch("recipe"))
    contents = JSON.generate(worker_records)
    path.write(contents)
    with_env(HOMEBREW_COOLDOWN_WORKER_DIGEST: Digest::SHA256.hexdigest(contents)) do
      Homebrew.failed = false
      FormulaInstaller.new(fish).post_install
      raise "Worker accepted #{description}" unless Homebrew.failed?
    end
  end
  failure = JSON.parse(report.read)
  unless failure.fetch("class") == error_class && failure.fetch("message").include?(message)
    raise "#{description} failed for an unrelated reason: #{failure}"
  end
  raise "#{description} changed package inventory" unless inventory == before
  puts "PASS: refused #{description} in native sandboxed worker"
ensure
  report.unlink if owns_report && report.file?
end

# A changed handoff must fail before recipe evaluation, even if it is valid JSON.
before = inventory
BrewCooldown::Executor::Postinstall.with_map(map) do
  (BrewCooldown::Executor.worker_plan/"recipes.json").write("[]")
  Homebrew.failed = false
  FormulaInstaller.new(fish).post_install
  raise "Worker accepted altered recipe map" unless Homebrew.failed?
end
raise "Altered map changed package inventory" unless inventory == before
Homebrew.failed = false
puts "PASS: refused changed recipe map before evaluation"

BrewCooldown::Executor::Postinstall.with_map(map) { FormulaInstaller.new(fish).post_install }
raise "Worker also rejected the original official hook" if Homebrew.failed?
puts "PASS: original official hook still succeeds after refusal probes"
