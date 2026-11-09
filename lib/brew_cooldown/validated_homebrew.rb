# frozen_string_literal: true

module BrewCooldown
  # The installer adapter prepends guards to Homebrew internals that carry no
  # compatibility promise, so execution is qualified one Homebrew commit at a
  # time. Move this only together with the VM evidence for the new commit: the
  # Qualify workflow's run on the pull request that moves it (CONTRIBUTING.md).
  # The file loads without Homebrew so tooling can read the same value the
  # executor enforces.
  VALIDATED_HOMEBREW_COMMIT = "bc63375ac3a4d6debb1ceb441ae6e22854f0909a"
end
