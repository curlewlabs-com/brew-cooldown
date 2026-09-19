# Cask execution

Status: the native historical Codex install and upgrade experiment passed.
Historical discovery and policy selection are connected to `plan`. Component
execution and recovery integration are the next step; the command does not yet
execute casks.

## Source, artifact and age

Use the official Homebrew cask API to establish canonical identity and the
current source path. Enumerate that path's reachable history in
`Homebrew/homebrew-cask`, anchored to an observed repository head. Resolve each
recipe at an immutable commit, verify its content identity, and evaluate the
original Ruby with Homebrew's cask loader. Do not synthesize a current API recipe
with an older version substituted into it.

The recipe supplies the platform-specific vendor URL and checksum. Downloads
use Homebrew's cask cache, checksum verification and quarantine behavior.
Require a concrete version and checksum before using a release-age decision.
Candidate identity includes canonical package identity, platform, evaluated
version, recipe digest and download digest. A recipe change cannot borrow the
age of a different recipe for the same upstream version.

A source commit that contains the exact recipe and download checksum provides
publication evidence for that combination. Validate the commit's date, retain
its immutable reference in the in-memory candidate, and use the existing
first-observation fallback when reliable publication evidence is unavailable.
Fresh current metadata and reachable history must still authorize the selected
candidate immediately before execution. A current rollback, withdrawal or
changed download cannot inherit an earlier plan's authorization.

## Installed identity and dependencies

Use the native cask receipt and installed cask metadata, including Homebrew's
pin state. Those records remain the installed authority; the tool adds no
installation receipt. Homebrew's installed metadata supplies the old artifacts
used for native uninstall and upgrade operations.

A cask's formula dependency declaration is a runtime package requirement.
Unlike a bottle's build-time dependency record, its receipt records the local
formula graph at installation. Do not turn that observation into an exact ABI
requirement. Bind cask dependency lookups to the selected native formula map,
require active installed dependencies before entering the cask installer, and
validate the cask's actual declared dependency contract. Formula consumers
continue to impose their own stronger bottle compatibility requirements.

The native installer also resolves extraction-tool dependencies. Include these
in the validated map when needed; report an unplanned dependency before it can
be installed. Missing dependencies must be separate planned operations, never
an implicit latest-version installation initiated by a cask.

## Execution and recovery

Run cask execution in the isolated component worker. A process-local map binds
the exact new cask and the installed predecessor. Guard cask loading and
installer entrypoints so recursive installation, current-recipe substitution
and unplanned formula operations fail before mutation. Preserve native
platform, conflict, checksum, quarantine and pin checks.

The first experiment covers native binary and generated-completion artifacts,
the artifact types used by the selected Codex recipes. Additional artifact and
hook behavior needs equivalent execution evidence. The adapter does not run
zap as part of an upgrade.

Journal cask operations before mutation and verify the native receipt and
installed artifacts before recording completion. Homebrew's own best-effort
restoration after a failed cask upgrade remains active; brew-cooldown adds no
automatic rollback or journal replay. An interrupted operation remains
unconfirmed until inspected and explicitly acknowledged. Recovery instructions
identify cask commands and distinguish native forward repair from any retained
artifact restoration actually available.

## Qualification

In a disposable Apple Silicon VM, install the historical baseline, upgrade to
a specified historical recipe while a newer release exists, and run the
installed binary. Check receipts, generated completions and formula inventory.
Attempt a current-recipe substitution and an unplanned dependency installation
and verify rejection before mutation. Exercise pins, changed evidence,
interruption and native failure recovery when the command integration lands.

## Observed result

On 2026-09-18, a disposable Apple Silicon macOS VM ran ordinary `brew update`,
advancing its Homebrew checkout to the validated commit recorded in
[installer boundaries](installer-boundaries.md). The experiment then installed
Codex 0.144.5 and upgraded it to 0.144.6 using official historical recipes while
the current Homebrew API advertised 0.155.1.

The selected executable reported the expected version, generated shell
completions existed, and native receipts retained the selected source commit,
version, tap and ripgrep runtime dependency. Formula receipt and link inventory
was unchanged. The guards rejected an unplanned cask lookup, a different cask
object with the same token, an implicit dependency installation when ripgrep's
active link was temporarily absent, and a native cask pin.

`test/integration/cask_candidates.json` holds the immutable official source
references used by this experiment. These are test fixtures, not a production
history catalog. In an expendable VM with ripgrep installed and Codex absent:

```sh
export HOMEBREW_COOLDOWN_DISPOSABLE=1
export HOMEBREW_DEVELOPER=1
export HOMEBREW_NO_AUTO_UPDATE=1
export HOMEBREW_NO_INSTALL_CLEANUP=1
brew ruby -- test/integration/cask_install.rb baseline
brew ruby -- test/integration/cask_install.rb upgrade
```

These commands intentionally install historical software. They do not exercise
the policy or journal yet, and are not workstation upgrade commands.
