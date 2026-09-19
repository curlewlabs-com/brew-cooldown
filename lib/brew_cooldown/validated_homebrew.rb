# frozen_string_literal: true

module BrewCooldown
  # The installer adapter prepends guards to Homebrew internals that carry no
  # compatibility promise, so execution is qualified one Homebrew commit at a
  # time. Move this only together with the VM evidence for the new commit; see
  # docs/scheduled-adoption.md. The file loads without Homebrew so tooling can
  # read the same value the executor enforces.
  VALIDATED_HOMEBREW_COMMIT = "edb70f031e4170c780799633a1226ff73e1077f4"
end
