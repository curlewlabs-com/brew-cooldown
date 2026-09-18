# Installer boundary experiments

Status: the ordinary post-install experiment passed. The concurrency experiment
found that Homebrew package locks do not protect all relevant peer operations.
Unattended execution remains blocked under the current design. These are
destructive experiments for an expendable VM, not supported upgrade commands.

## Observed post-install behavior

On 2026-09-18, the experiments used macOS 26.6.2 on Apple Silicon at
`/opt/homebrew`, with Homebrew commit
`edb70f031e4170c780799633a1226ff73e1077f4`.

The official fish 4.0.6 bottle installed with ncurses 6.5 and PCRE2 10.46.
The candidate loader verified the bottle attestations before loading their
embedded recipes. Homebrew's native sandboxed worker ran fish's original
Ruby post-install hook. Its output directories were absent from the bottle
and present after installation. A PCRE expression executed successfully through
fish, and its canonical `opt` link selected the historical keg.

The adapter keeps Homebrew's native post-install command and sandbox. At its
subprocess boundary, it preloads a resolver carrying only parent-verified
recipes. The parent owns a private temporary directory containing the recipe
map and worker preload, passes the map's content digest, and deletes the
handoff when the synchronous operation ends. The sandbox denies worker writes
to that directory. The worker verifies the map and recipe digests before
evaluation. This is temporary invocation state, not a release catalog.

Worker formula resolution accepts only selected canonical identities and exact
recipe paths. Installer construction is refused. The sandbox denies reading
the brew launcher, preventing the tested recursive command-line invocation.
Unexpected subprocess arguments or unavailable native sandboxing stop the
operation. Homebrew's failure flag is checked; a hook failure after pouring
is a partial failure, not a successful installation.

This is a boundary around trusted official hooks, not a general sandbox for
hostile Ruby or third-party recipes. Arbitrary direct filesystem changes,
alternative entrypoints into Homebrew, service effects, declarative hooks and
all possible child-process patterns have not been proven safe.

## Observed concurrency failure

The lock experiment held the native fish `FormulaLock` in one process and ran
real Homebrew operations in another. A direct competing lock acquisition was
refused, establishing that the lock was actually held. Nevertheless:

- `brew pin fish` created a pin while that package lock remained held.
- The native reinstall command moved the active fish keg aside before calling
  `FormulaInstaller#lock`. The original keg and its executable were absent at
  that boundary. Lock acquisition then failed, and Homebrew restored the old
  receipt, link and executable. The restored executable passed its PCRE check.

The reinstall probe only observes state at the native lock method before
calling its original implementation. It does not replace locking, move the
keg itself or reorder installation. The command's normal dependent-repair
phase is disabled for this isolated probe; the observed failure occurs before
that phase and before any new bottle is installed.

This corroborates the inspected Homebrew code: `FormulaPin#pin_at` changes a
symlink without a package lock, and `Reinstall.reinstall_formula` calls
`backup` before `FormulaInstaller#install` acquires its lock. Native recovery
works for this refusal, but the intermediate state was not protected. No
process interruption was injected, and this is not journal reconciliation.

Taking locks earlier in our own adapter cannot make an independent Homebrew
process take them earlier. An inventory check can detect a change but cannot
prevent a peer from changing state immediately afterward. A tool-specific
lock only coordinates callers that participate in it. These results block
the stronger concurrency contract in the
[system design](design.md#applying-a-plan).
They do not establish that serial historical installation is impossible.

## Decision needed before unattended execution

The operating contract must explicitly choose how the prefix is shared:

- Require a managed prefix with an exclusive writer, with all package mutations
  routed through the same scheduler or lock. This can avoid depending on an
  upstream change, but needs enforceable host integration; merely asking users
  not to run brew is not an isolation mechanism.
- Support ordinary concurrent Homebrew writers after the required native
  operations honor the same locks before mutation. That requires upstream
  changes or a different isolation boundary, beyond a process-local adapter.
- Accept interference from concurrent Homebrew commands, detect it where
  possible, and report partial failures. This weakens the current guarantee
  and must be an explicit product decision, not a hidden fallback.

No option requires a private artifact archive or release database. Broader
planner and unattended-executor implementation is paused at this feasibility
boundary rather than silently selecting an operating contract.

## Reproduce

Use an expendable VM with the prerequisites and environment from the
[historical experiment](installer-proof.md#reproduce-in-a-disposable-vm).
Start without fish, ncurses or PCRE2 installed. Run from the checkout:

```sh
brew ruby -- test/integration/hook_install.rb
brew ruby -- test/integration/hook_refusal.rb
export HOMEBREW_NO_INSTALLED_DEPENDENTS_CHECK=1
brew ruby -- test/integration/lock_boundary.rb
```

The hook refusal experiment uses deliberately altered hook fixtures after
preparing the official candidate map. Those fixtures are never installation
candidates or represented as signed recipes. They attempt an unplanned formula
lookup, installer construction, recursive brew invocation and a worker write
to the handoff. It also changes the handoff without changing its digest.
Refusals must preserve package receipts and `opt` links. The original official
hook must still succeed.

The lock experiment exits nonzero with `BLOCKED` when it reproduces the native
concurrency gap. A failure before reaching its lock observation is a test
error, not proof of the gap. `lock_peer.rb` is its subprocess helper; do not
run the reinstall mode independently. Destroy the VM after the experiments.

## Remaining acceptance work

The shared-consumer upgrade and refusal experiments, adapter identity change,
inventory change before apply, interpreter upgrades, interruption and journal
reconciliation remain unproven. The complete release bar remains in
[verification](verification.md). Passing the hook experiment does not satisfy
that bar or make this a replacement for a scheduled Brewfile job.
