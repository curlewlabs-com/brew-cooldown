# Contributing

Thanks for your interest in improving `brew-cooldown`. The bar for a change is
"does this make a delayed upgrade safer, more explainable, or possible for more
packages without weakening what the policy promises". Bug fixes, sharper
diagnostics, support for another cask artifact type with execution evidence,
and clearer docs are all welcome.

## Before a large change

Open an issue describing the problem first. The installer guards, the journal
and the advisory assessment carry the safety invariants, and the
[system design](docs/design.md) records decisions that are easy to undo by
accident: no private release catalog, no durable state beyond the observation
ledger and the unfinished journal, and no fallback to a latest-only upgrade. A
short discussion up front saves rework.

## Running the checks

```sh
script/unit-tests
shellcheck bin/brew-cooldown script/unit-tests script/qualify \
  script/propose-homebrew-release script/merge-homebrew-release
```

CI runs both on every pull request, the suite on Apple Silicon macOS with
Homebrew pinned to the qualified commit. `script/unit-tests` parses every Ruby
source and runs `test/unit` through Homebrew's own Ruby, so locally it needs
only a Homebrew installation. The unit tests
use fixed timestamps and recorded upstream responses; they install nothing and
make no network requests.

A few probes under `test/integration` leave installed packages alone and are
safe on a workstation: `advisories.rb`, `registry.rb` and
`current_formulae.rb` query the live upstream sources,
`installed_inventory.rb` reads the installed packages,
`command_help.rb` checks help dispatch, and `command_recovery.rb` drives
`recover` against a temporary state directory. Run one with
`HOMEBREW_DEVELOPER=1 brew ruby -- test/integration/registry.rb`.

Every other integration test installs, upgrades, pins or interrupts real
packages. They refuse to start without `HOMEBREW_COOLDOWN_DISPOSABLE=1`, and
that variable belongs only in an expendable Apple Silicon macOS VM. The
[installer experiment](docs/installer-proof.md),
[boundary experiments](docs/installer-boundaries.md),
[execution and recovery](docs/execution-recovery.md) and
[cask execution](docs/cask-execution.md) describe each fixture and the order to
run them in, and `script/qualify` runs them in those orders, one track per VM.
The [Qualify workflow](.github/workflows/qualify.yml) gives each track its own
GitHub-hosted macOS job, which is such a VM: GitHub discards it when the job
ends. Never set that variable on a machine you care about.

## Conventions

- **Tests ship with the change.** A bug fix or feature includes its test in the
  same pull request.
- **Use real Homebrew, not a model of it.** Version ordering, advisory ranges,
  Brewfile evaluation and installation go through Homebrew's own code. A mocked
  installer only proves that the mock agrees with itself, so installation
  claims need VM evidence. Recorded upstream responses are fine as fixtures;
  say where and when they were retrieved.
- **Time is an input.** Policy code never reads the clock. Tests pass fixed UTC
  instants and cover a local date that differs from the UTC date.
- **Keep Homebrew internals in the adapter.** The policy and the planner take
  plain records. Homebrew does not promise stable internal APIs, so every use
  of one is a place the next Homebrew release can break.
- **Fail closed and say why.** Missing evidence is reported as missing, never
  treated as old, safe or empty. Errors name the operation and the package.
- **Comments explain _why_, not _what_.** Most of the non-obvious code here is
  non-obvious because of a Homebrew behavior that was observed. Keep that
  reason with the code.
- **Keep tracked text ASCII.** Use plain hyphens, `->`, and words instead of
  Unicode punctuation or decorative symbols.

## Supporting a newer Homebrew

`upgrade` runs only on the Homebrew commit the installer adapter was qualified
against. Supporting a newer commit means moving `VALIDATED_HOMEBREW_COMMIT` in
`lib/brew_cooldown/validated_homebrew.rb` in a pull request. That pull request
runs the Qualify workflow, which reruns every VM experiment on the new commit.
Its passing `qualified` check is the evidence, so merge only after it. A version
range is never a substitute for that run.

The [Homebrew release workflow](.github/workflows/homebrew-release.yml) opens
that pull request itself when Homebrew tags a release, starts CI and the Qualify
workflow on it, and merges it on a later run once `qualified` passes. It merges
only a branch that still moves nothing but the constant, to the tag's commit, and
is up to date with `main`. A draft, or any other change pushed to the branch,
such as the adapter fix a failing track needs, leaves the merge to a person.

To rerun one track elsewhere, prepare a VM as `script/qualify` describes and run
`HOMEBREW_COOLDOWN_DISPOSABLE=1 script/qualify TRACK`; `--list` names the
tracks.

## Submitting

Keep each pull request focused on one change, make sure the checks pass, and
describe the _why_ in the pull request body. CI must be green before merge.
