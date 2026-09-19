# frozen_string_literal: true

require "open3"

launcher = File.expand_path("../../bin/brew-cooldown", __dir__)
environment = {
  "PATH" => "#{File.dirname(launcher)}:#{ENV.fetch('PATH')}",
  # Enter as a user command, without the parent `brew ruby` saved search path.
  "HOMEBREW_PATH" => nil,
  "HOMEBREW_NO_AUTO_UPDATE" => "1",
}

# Homebrew's external-command help must reach our parser through the nested
# `brew ruby` invocation, rather than successfully printing the wrong help.
[
  [launcher, "--help"],
  [HOMEBREW_BREW_FILE.to_s, "cooldown", "--help"],
  [HOMEBREW_BREW_FILE.to_s, "cooldown", "-h"],
  [HOMEBREW_BREW_FILE.to_s, "help", "cooldown"],
].each do |command|
  stdout, stderr, status = Open3.capture3(environment, *command)
  warn stderr unless stderr.empty?
  raise "Wrong command help for #{command.inspect}" unless status.success? &&
    stdout.start_with?("Usage: brew-cooldown ") && stdout.include?("--brewfile")
end
puts "PASS: direct and Homebrew external-command help"
