# frozen_string_literal: true

require "formula_installer"

abort "Run only in an expendable VM" unless ENV["HOMEBREW_COOLDOWN_DISPOSABLE"] == "1"

case ARGV.fetch(0)
when "contend"
  FormulaLock.new("fish").with_lock { puts "Acquired fish lock" }
when "reinstall"
  require "cmd/reinstall"

  # Observe the real command immediately before its native lock attempt.
  # This changes neither Homebrew's execution order nor its failure handling.
  module LockObservation
    def lock
      if formula.name == "fish"
        keg = HOMEBREW_CELLAR/"fish/4.0.6"
        puts "LOCK_OBSERVATION #{JSON.generate(keg_exists: keg.directory?, executable_exists: (keg/"bin/fish").executable?)}"
        $stdout.flush
      end
      super
    end
  end

  FormulaInstaller.prepend(LockObservation)
  Homebrew::Cmd::Reinstall.new(["--formula", "--no-ask", "fish"]).run
  exit 1 if Homebrew.failed?
else
  abort "Unknown lock probe"
end
