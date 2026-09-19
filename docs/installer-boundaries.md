# Installer boundary experiments

Status: the ordinary post-install experiment passed. The concurrency experiment
found that Homebrew package locks do not protect all relevant peer operations.
The operating contract accepts this limitation and recommends avoiding
overlapping mutations. These are destructive experiments for an expendable
VM, not supported upgrade commands.

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
lock only coordinates callers that participate in it. The
[system design](design.md#applying-a-plan) accepts this interference risk and
requires drift reporting with text-only recovery choices.

## Operating contract

Avoid overlapping package-changing Homebrew commands. Use native package
locks before our own mutations and inspect inventory again, but do not try to
enforce exclusive prefix ownership. A native peer can still change a pin or
move an active keg. Detect drift where possible, report partial results, and
print commands for restoring a retained installation or repairing forward.
The user chooses and runs any repair; its effects and cooldown implications
must be explicit.

The concurrency experiment remains useful evidence of this limitation. It no
longer blocks implementation. Continue attempting valid candidates and
independent components, with specific errors when progress is not possible.
This decision needs neither upstream coordination nor another artifact store.

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

The lock experiment reports the observed native concurrency gap and verifies
recovery after the contending command fails. Unexpected failures or incomplete
restoration fail the experiment. `lock_peer.rb` is its subprocess helper; do not
run the reinstall mode independently. Destroy the VM after the experiments.

## Shared consumer result

The shared-consumer experiment passed on the same platform and Homebrew
commit. It installed fish 4.7.1 with PCRE2 10.47_1, then upgraded PCRE2 to
10.48 while retaining fish's receipt and canonical link. Matching recorded
Homebrew compatibility identifiers and the required candidate library paths
supported the change. Native linkage inspection and a PCRE-backed fish command
passed afterward. A candidate without the required compatibility evidence was
rejected before mutation; an attempt to reinstall the retained consumer was
also rejected.

This is evidence for the exercised dependency edge, not an inferred ABI promise
for every package. Installed receipts supply consumer requirements. Where the
recorded build differs, missing compatibility metadata remains a constraint
for the planner to resolve with another candidate or explain to the user.

Start a separate expendable VM without fish or PCRE2 and run:

```sh
brew ruby -- test/integration/shared_consumer.rb baseline
brew ruby -- test/integration/shared_consumer.rb insufficient_evidence
brew ruby -- test/integration/shared_consumer.rb upgrade
```

## Remaining acceptance work

The [execution experiments](execution-recovery.md) cover pin drift,
interruption, journal reconciliation and subsequent completion. Modifying the
Homebrew checkout also produced an error before package mutation. The recovery
experiment executed the printed retained-keg commands as an explicit operator
choice, restored the historical versions and passed the PCRE runtime check.

The interpreter experiment installed ruby@3.3 3.3.11 and upgraded it to 3.3.12
through the executor. Its native hook succeeded, and the upgraded interpreter
loaded OpenSSL and Psych. The tool's process and Homebrew-owned Ruby executable
remained unchanged throughout. Keg-only formulae retain their existing prefix
link choice; the adapter does not invoke native automatic promotion of a new
versioned formula onto the prefix's executable paths.

Installed dependency relationships with neither endpoint changing are retained.
For a replacement, the installed recipe and consumer receipt supply
compatibility evidence. A poured receipt can omit a compatibility identifier
present in the recipe stored inside that same keg. The adapter uses that recipe and
rejects an explicitly conflicting receipt; it does not load today's recipe to
invent compatibility for an old installation.

With the interpreter fixture's dependencies installed in the expendable VM:

```sh
export HOMEBREW_COOLDOWN_TEST_STATE="$PWD/interpreter-state"
brew ruby -- test/integration/interpreter_upgrade.rb baseline
brew ruby -- test/integration/interpreter_upgrade.rb upgrade
```

General history discovery, policy-driven graph selection and public commands
remain to be connected to these prototypes. The complete release bar remains
in [verification](verification.md). These experiments do not yet make this a
replacement for a scheduled Brewfile job.
