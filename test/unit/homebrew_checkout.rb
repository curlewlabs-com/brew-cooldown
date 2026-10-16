# frozen_string_literal: true

require "open3"
require "tmpdir"
require_relative "../../lib/brew_cooldown/executor/execution"

# Real git repositories stand in for Homebrew's checkout; only the identity of
# the qualified commit is injected, since a test cannot mint a known SHA.
def git(directory, *arguments)
  # A contributor's signing or hook settings must not decide these commits.
  output, status = Open3.capture2e("git", "-C", directory, "-c", "commit.gpgsign=false", "-c", "tag.gpgsign=false",
                                   "-c", "core.hooksPath=/dev/null", "-c", "user.name=test",
                                   "-c", "user.email=test@example.invalid", *arguments)
  raise "git #{arguments.join(" ")} failed: #{output}" unless status.success?

  output.strip
end

def refusal(directory, validated)
  BrewCooldown::Executor::Execution.check_checkout!(directory, validated:)
  nil
rescue BrewCooldown::Executor::Refused => error
  error.message
end

Dir.mktmpdir("cooldown-homebrew-checkout-") do |directory|
  git(directory, "init", "--quiet")
  File.write(File.join(directory, "brew.sh"), "release\n")
  git(directory, "add", "brew.sh")
  git(directory, "commit", "--quiet", "-m", "release")
  git(directory, "tag", "7.0.9")
  qualified = git(directory, "rev-parse", "HEAD")

  raise "Qualified clean checkout was refused: #{refusal(directory, qualified)}" unless refusal(directory, qualified).nil?

  # A local edit replaces adapter-guarded code just as surely as a new commit.
  File.write(File.join(directory, "brew.sh"), "edited\n")
  raise "Edited checkout was accepted" unless refusal(directory, qualified) == "Homebrew checkout changed"

  git(directory, "checkout", "--quiet", "--", "brew.sh")

  git(directory, "commit", "--quiet", "--allow-empty", "-m", "between releases")
  between = refusal(directory, qualified)
  # This is what `brew update` produces in developer mode. Waiting for a
  # qualification would never end, so the refusal has to name the repair.
  raise "Checkout between releases was accepted" if between.nil?
  ["7.0.9-1-g", "not a Homebrew release", qualified, "plan and explain still work",
   "brew developer off", "HOMEBREW_UPDATE_TO_TAG=1", "brew update --force"].each do |fragment|
    raise "Between-releases refusal lacks #{fragment.inspect}: #{between}" unless between.include?(fragment)
  end

  # Only the tag shape `brew update` selects marks a release.
  git(directory, "tag", "nightly")
  raise "A non-release tag counted as a release" unless refusal(directory, qualified).include?("not a Homebrew release")

  # A newer release awaits qualification; the developer-mode repair would
  # mislead, because `brew update` already lands on releases here.
  git(directory, "tag", "7.0.10")
  release = refusal(directory, qualified)
  raise "Unqualified release was accepted" if release.nil?
  raise "Release refusal lost the qualified commit: #{release}" unless release.include?(qualified)
  raise "Release was reported as a non-release: #{release}" if release.include?("not a Homebrew release")
  raise "Release refusal suggested the developer-mode repair: #{release}" if release.include?("brew developer off")
end
puts "PASS: Homebrew checkout refusals distinguish an unqualified release from a non-release"
