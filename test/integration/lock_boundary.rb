# frozen_string_literal: true

require "open3"
require "formula"

abort "Run only in an expendable VM" unless ENV["HOMEBREW_COOLDOWN_DISPOSABLE"] == "1"
abort "This proof requires Apple Silicon Tahoe at /opt/homebrew" unless
  HOMEBREW_PREFIX.to_s == "/opt/homebrew" && Utils::Bottles.tag.to_sym == :arm64_tahoe

expected = "edb70f031e4170c780799633a1226ff73e1077f4"
commit, status = Open3.capture2("git", "-C", HOMEBREW_REPOSITORY.to_s, "rev-parse", "HEAD")
abort "Uninspected Homebrew checkout" unless status.success? && commit.strip == expected
changes, status = Open3.capture2("git", "-C", HOMEBREW_REPOSITORY.to_s, "status", "--porcelain", "--untracked-files=no")
abort "Modified Homebrew checkout" unless status.success? && changes.empty?

keg = HOMEBREW_CELLAR/"fish/4.0.6"
pin = HOMEBREW_PINNED_KEGS/"fish"
raise "Run hook_install.rb first" unless (keg/"bin/fish").executable?
raise "Experiment requires fish unpinned" if pin.symlink?
before_receipt = (keg/"INSTALL_RECEIPT.json").binread
before_opt = (HOMEBREW_PREFIX/"opt/fish").readlink
brew = HOMEBREW_BREW_FILE.to_s
peer = File.join(__dir__, "lock_peer.rb")
findings = []
pin_created = false

begin
  FormulaLock.new("fish").with_lock do
    output, status = Open3.capture2e(brew, "ruby", "--", peer, "contend")
    raise "Contending process acquired the package lock: #{output}" if status.success?
    raise "Contention failed for an unrelated reason: #{output}" unless output.include?("OperationInProgressError")
    puts "PASS: native package lock excludes a second lock holder"

    output, status = Open3.capture2e(brew, "pin", "--formula", "fish")
    pin_created = pin.symlink?
    if status.success? && pin_created
      findings << "pin changed while the native package lock was held"
      puts "OBSERVED: #{findings.last}"
    elsif !output.include?("already locked")
      raise "Pin probe failed for an unrelated reason: #{output}"
    end

    # Undo only the pin created by this experiment before the reinstall probe.
    if pin_created
      raise "Experiment pin target changed" unless pin.realpath == keg
      output, status = Open3.capture2e(brew, "unpin", "--formula", "fish")
      raise "Could not remove experiment pin: #{output}" unless status.success? && !pin.symlink?
      pin_created = false
    end

    output, status = Open3.capture2e(brew, "ruby", "--", peer, "reinstall")
    puts output
    raise "Contending reinstall unexpectedly succeeded" if status.success?
    raise "Reinstall failed for an unrelated reason" unless output.include?("already locked")
    observation = output.lines.find { |line| line.start_with?("LOCK_OBSERVATION ") }
    raise "Reinstall did not reach its native lock boundary" unless observation
    state = JSON.parse(observation.delete_prefix("LOCK_OBSERVATION "))
    unless state.fetch("keg_exists") && state.fetch("executable_exists")
      findings << "reinstall removed the active keg before failing to acquire its package lock"
      puts "OBSERVED: #{findings.last}"
    end
  end
ensure
  if pin_created && pin.symlink? && pin.realpath == keg
    output, status = Open3.capture2e(brew, "unpin", "--formula", "fish")
    raise "Could not remove experiment pin: #{output}" unless status.success?
  end
end

raise "Reinstall failed to restore the receipt" unless (keg/"INSTALL_RECEIPT.json").binread == before_receipt
raise "Reinstall failed to restore the opt link" unless (HOMEBREW_PREFIX/"opt/fish").readlink == before_opt
output, status = Open3.capture2((keg/"bin/fish").to_s, "-c", "string match -r 'a(?=b)' ab")
raise "Reinstall failed to restore runnable fish" unless status.success? && output == "a\n"
puts "PASS: native failure recovery restored the historical installation"
if findings.empty?
  puts "PASS: observed peer operations respected the held package lock"
else
  puts "PASS: reproduced accepted concurrency limitation: #{findings.join('; ')}"
end
