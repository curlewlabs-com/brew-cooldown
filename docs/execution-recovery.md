# Execution and recovery

Status: the execution and interruption experiments passed on the platform and
Homebrew commit recorded in [installer boundaries](installer-boundaries.md).
This remains a prototype, without a public recovery command.

Execute a dependency-ordered component through native installers. Prepare and
verify candidates before mutation. Acquire the tool's prefix-scoped lock and
native package locks, then re-read receipts, active links, pins and the Homebrew
identity. A changed assumption is reported as drift and passed back for
replanning. The native locks reduce collisions but cannot exclude all external
Homebrew writers; avoid overlapping package-changing commands.

## Operational state

The state directory belongs to the tool, namespaced by canonical Homebrew
prefix. Its lock remains at a stable path; never unlink a lock another process
might have opened. Kernel-held file locks identify the owning process and
release on death. A private temporary file is flushed, renamed over the active
journal and its directory synced. Failure to persist an intended operation
prevents that mutation. Failure to persist its result leaves it unconfirmed.

The journal records selected identities and the baseline inventory, with
package states `pending`, `started`, `completed` or `failed`. Persist `started`
before unlinking the old package. Persist `completed` only after native finish,
receipt and link verification, and required consumer linkage checks. The
journal stores evidence references and inventory fingerprints, not recipes or
artifacts. Homebrew owns reusable downloads.

The tool owns changes only to the planned packages. A component holds its native
locks until completion; native per-installer cleanup must not release them
early. A new invocation reads an unfinished journal before any mutation.
Unstarted work is not presented as failed and an installed receipt alone does
not prove that a hook completed. An interrupted `started` operation remains
unconfirmed even if its selected keg exists. The operator can repair that
state and explicitly accept the current inventory to enable a fresh plan.

## Recovery output

Report the operation, expected version and active path, observed inventory,
and the underlying error. Keep completed, failed, unconfirmed and pending work
visible. Offer inspection commands first. Offer restoring links to the retained
old keg only when it still exists, or a native reinstall to repair forward.
Quote every shell argument. Native reinstall adopts Homebrew's current release
and is outside the tool's cooldown selection; relinking does not undo changes
made by a post-install hook. Do not suggest forced overwrites or unpinning as
automatic repair.

These are text commands. Neither error reporting nor journal inspection runs
them. Explicitly accepting a repaired inventory acknowledges uncertainty about
hooks; it does not execute or certify their side effects. Subsequent upgrades
must plan again from the actual inventory, current pins and refreshed evidence.

## Verification boundaries

Use actual native installations in the disposable VM. Inject drift after
planning and before execution, then assert that the installation does not start
and that recovery commands name the affected package. Kill the process after
a package boundary and inspect its on-disk journal from a fresh process. Show
completed and pending work separately, without replaying either automatically.
Exercise an unconfirmed operation and a confirmed completion independently.

Inventory fingerprints cover receipt bytes, active and canonical links, pins
and installed recipe bytes. They do not claim to detect arbitrary edits to all
package payload files. A Homebrew identity check verifies the inspected commit
and tracked checkout state. Filesystem races with nonparticipating writers
remain possible after inspection; errors and partial results must stay visible.

## Observed results

A native `brew pin pcre2` after the inventory snapshot caused a drift result
with inspection and forward-repair commands. Execution left that changed
inventory untouched. A child terminated by SIGKILL after persisting `started`
was reported as unconfirmed from a fresh process, with ripgrep still pending.
Explicit acceptance removed the journal without changing installed packages.
A subsequent complete execution upgraded PCRE2 10.46 to 10.47 and ripgrep
15.0.0 to 15.1.0, verified linkage, passed a PCRE runtime check and removed the
finished journal.

A separate interruption after completing PCRE2 preserved its completed state
and ripgrep's pending state. After explicit acceptance, a fresh candidate map
retained the already upgraded PCRE2 and completed the ripgrep upgrade.

In an expendable VM with the historical experiment's baseline installed:

```sh
export HOMEBREW_COOLDOWN_TEST_STATE="$PWD/experiment-state"
brew ruby -- test/integration/execution_recovery.rb drift
brew ruby -- test/integration/execution_recovery.rb crash_check interrupt_started
brew ruby -- test/integration/execution_recovery.rb unconfirmed
brew ruby -- test/integration/execution_recovery.rb accept
brew ruby -- test/integration/execution_recovery.rb complete
```

To exercise interruption after the dependency completes, begin again from the
historical baseline, use `crash_check interrupt`, then `reconcile`, `accept`
and `resume`. Acceptance is an explicit operator decision in these experiments;
normal execution never accepts unfinished work automatically.
