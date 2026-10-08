# Cask execution

Status: historical discovery, policy selection, component execution and recovery
are connected to the commands. The native cask adapter supports the binary and
generated-completion artifacts used by Codex, plus the bounded native contracts
below, on the validated Homebrew runtime. Native support is qualified by the
pull request's `qualified` check, not by passing workstation unit tests.

## Source, artifact and age

Use the official Homebrew cask API to establish canonical identity and the
current source path. Enumerate that path's reachable history in
`Homebrew/homebrew-cask`, anchored to an observed repository head. Resolve each
recipe at an immutable commit, verify its content identity, and evaluate the
original Ruby with Homebrew's cask loader. Do not synthesize a current API
recipe with an older version substituted into it.

Walk that history from its newest commit, a page at a time, and stop at the
installed version. Older commits were superseded before this installation, and
a higher version further back is one Homebrew later rolled back, so neither can
be a candidate. Stopping there also bounds the GitHub requests by the commits
since installation instead of by the age of the cask. A cask without an
installed baseline still walks its whole history.

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

The component coordinator orders formula and cask operations from their runtime
dependencies and owns the journal and inventory checks. Native operation
adapters own installation and completion verification. Journal operation
identity includes package kind so a formula and cask sharing a token remain
distinct. Formula locks retain their existing native ownership; avoid concurrent
package-changing Homebrew commands, including cask commands.

The first experiment covers native binary and generated-completion artifacts,
the artifact types used by the selected Codex recipes. Additional artifact and
hook behavior needs equivalent execution evidence. The adapter does not run
zap as part of an upgrade.

Completion reads the persisted native receipt rather than Homebrew's in-process
Tab cache, checks its version and source commit, and verifies binary targets and
generated-completion paths. Formula dependencies keep their native linkage
checks. No supplemental installed-artifact receipt is written.

Journal cask operations before mutation and verify the native receipt and
installed artifacts before recording completion. Homebrew's own best-effort
restoration after a failed cask upgrade remains active; brew-cooldown adds no
automatic rollback or journal replay. An interrupted operation remains
unconfirmed until inspected and explicitly acknowledged. Recovery instructions
identify cask commands and distinguish native forward repair from any retained
artifact restoration actually available.

## Qualification

### Native SDK and package contracts

`gcloud-cli` and `tailscale-app` are official self-updating casks with executable
installation behavior. Their support is deliberately narrower than accepting
every `auto_updates` cask or every script or PKG artifact.

[NativeCaskContract](../lib/brew_cooldown/executor/native_cask_contract.rb) binds
the evaluated artifact classes, arguments, destinations, structured hook steps,
uninstall actions and package dependencies to qualified behavior signatures.
Installed API metadata keeps only uninstall artifacts and may have no tap on
the loaded object. Predecessor validation uses the native receipt's official
tap and a separate uninstall-behavior signature; it never reconstructs the
predecessor from today's recipe or requires discarded installation metadata.
Only the Tailscale PKG filename's concrete version is replaced by a placeholder;
the full recipe and download digests still identify each historical release.
Hash keys and top-level artifact entries are sorted for stable comparison;
ordering inside hooks, arguments and uninstall lists is preserved. Opaque Ruby
flight blocks remain refused because Homebrew's serialization does not bind
their executable contents. New native behavior requires updated evidence and
qualification before changing a signature. Signatures describe behavior, not a
production release catalog.

For gcloud, Homebrew runs the original structured preflight steps, vendor
installer, binary and shell-completion linking, postflight steps and native
uninstall. The SDK lives under `share/google-cloud-sdk`, outside its Caskroom,
and the hooks recreate its Python environment. The selected Python dependency
must already satisfy the shared plan. The vendor installer preserves optional
components and may download them; its process-scoped fixed-SDK-version setting
keeps them on the selected release. Native predecessor restoration receives
the predecessor's setting. Vendor commands use the declared Homebrew Python
interpreter; a versioned Python formula does not replace macOS's `python3`.
The Python-environment hook's external wheel download
remains vendor-managed hook behavior, not a Homebrew package operation or a
separately cooldown-assessed artifact. Zap is never run.

For Tailscale, Homebrew runs the checksum-verified historical PKG with macOS's
privileged installer and the predecessor's native uninstall actions. PKG
installation may request sudo authorization and affect application, helper and
system-extension state outside Homebrew. The app remains in `/Applications`;
custom artifact destinations do not inherit this qualification. Homebrew's
native uninstall controls quit, login-item preservation during upgrade, package
receipt removal and the recipe's explicit deletion paths. No broader uninstall
script or forced overwrite is authorized by the profile.

Manual `gcloud components update` and Tailscale's Sparkle updater still operate
outside this tool's policy. The adapter changes no persistent updater settings.
Operators requiring all adoption to pass through cooldowns must manage these
update mechanisms separately. See Google's
[component management](https://docs.cloud.google.com/sdk/docs/components) and
Tailscale's [update policies](https://tailscale.com/docs/features/tailscale-system-policies).
Inventory reads require the live SDK version and component snapshots, or the
Tailscale bundle and macOS package versions, to agree with the Homebrew receipt.
A self-update that leaves that receipt stale is an explicit inventory error;
it cannot supply a downgrade target or silently remove the cask from scope.

The shared drift fingerprint includes native SDK version/component metadata,
the Tailscale bundle plist and macOS package receipts. Both component execution
and the outer coordinator recognize only the relevant native metadata changes
as owned by that cask. Completion verifies those live versions as well as the
selected Homebrew receipt and source commit; gcloud's binary and completion
links must resolve to the selected source. Fingerprints do not claim to detect
arbitrary payload edits or exclude a racing external updater.

The native tracks in `script/qualify` use disposable Apple Silicon macOS VMs.
The recorded upstream recipes in `test/fixtures/native_casks` were retrieved
on 2026-10-08; their immutable source references and checksums live in
`test/integration/native_cask_candidates.json`. They exercise historical native
installation. The adjacent installed JSON fixtures contain receipt excerpts
from native API-managed installations on that date, with the machine's cache
path omitted, and exercise predecessor validation. The VM tracks exercise
historical native
installation, preservation of an optional SDK component, all-installed
assessment and command upgrades with an injected UTC timestamp, cooling
successors, native pins and payload drift. Interruption tracks kill the worker
after gcloud's preflight has copied the SDK or after Tailscale's PKG installer
has returned, before Homebrew writes the selected receipt. Fresh-process
inspection must keep those operations unconfirmed and leave packages unchanged.
The printed native forward-repair command is exercised before explicit journal
acknowledgment. Restoration of hooks, extensions or user configuration is not
certified by accepting a journal.

| Boundary | Native cask path |
| --- | --- |
| Official identity | Verified historical source; installed receipt supplies predecessor tap |
| Historical authority | Existing immutable recipe/download digests and current withdrawal checks |
| Policy | Existing cooldowns, native pins and independently assessed dependency graph |
| Recipe behavior | Full candidate signature and separate native predecessor uninstall signature |
| Mutation | Existing isolated worker, exact maps, native installer guards and journal |
| SDK component updates | Process-scoped selected SDK version; predecessor version during restoration |
| PKG privileges | Native macOS installer and recipe uninstall actions; no forced or untrusted options |
| External updater | Live payload/receipt agreement and additional inventory drift evidence |
| Completion | Persisted source receipt, live SDK/app/package versions and native link checks |
| Recovery | Existing read-only inspection, exact-evidence acknowledgment and text-only repair |

Homebrew evaluates the original Ruby and normalizes structured steps; no Ruby
text parser is introduced. The behavior signature is separate from release
identity: no age or provenance is inferred from its equality. Native external
metadata has explicit ownership at both inventory consumers. The tool lock and
unchanged journal persistence govern the operation; no additional persistent
claim or payload cleanup primitive is introduced. External writers still can
race those checks, and interrupted hooks remain an operator reconciliation.

Homebrew's native Trash and application-identity APIs use Objective-C. macOS
can abort class initialization after a multithreaded process forks, as observed
in the gcloud command-upgrade qualification. The cask map delegates those APIs
to fresh Homebrew Ruby subprocesses. The same native APIs still own Trash,
permission retries and application identity; fork safety is not disabled.
This bridge does not load recipes or invoke package installers. The component
continues to own installer guards, policy revalidation and journaling.

| Subprocess boundary | Guard and ownership |
| --- | --- |
| Authorized mutation | Existing selected recipe and predecessor signatures still authorize uninstall actions before the bridge is reached |
| API selection | Closed native API dispatch; paths and PIDs are arguments, never Ruby or shell source |
| Input and result | Native argument semantics; exact JSON parser with checked result shapes and subprocess exit status |
| Installer resolution | Remains in the component's exact maps; the bridge loads no cask recipes and installs no packages |
| Error handling | Native failures remain native results; subprocess failures and unreadable results raise and retain the operation journal |
| Persistence and cleanup | Synchronous subprocesses introduce no saved plan, receipt, replay or payload cleanup |

### Binary cask contract

In a disposable Apple Silicon VM, install the historical baseline, upgrade to
a specified historical recipe while a newer release exists, and run the
installed binary. Check receipts, generated completions and formula inventory.
Attempt a current-recipe substitution and an unplanned dependency installation
and verify rejection before mutation. `test/integration/cask_recovery.rb`
exercises pins, interruption and native failure recovery through the shared
journal.

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

These commands intentionally install historical software. They exercise the
installer adapter alone, without the policy or the journal, and are not
workstation upgrade commands.

The command-level test is `test/integration/command_cask_upgrade.rb`.
In the disposable VM it selected and installed Codex 0.153.4 from a 0.144.6
baseline while Homebrew's current release was 0.155.1. The persisted receipt
matched the selected commit, the binary reported the selected version,
completions existed, formula inventory was unchanged, and the completed journal
was removed.

`test/integration/cask_recovery.rb` exercises native cask pins, binary
conflicts, worker termination and explicit recovery with a historical baseline.
A binary conflict can also prevent Homebrew's best-effort restoration; the
failed journal then remains even when native versioned files are absent. The
printed native forward-repair command is an operator choice outside the cooldown
policy, and repair does not acknowledge the journal automatically.

The native conflict test preserved the foreign binary file and failed journal.
Running the printed forward-repair command restored a runnable installation;
explicit acknowledgment then cleared the journal without changing packages.
SIGKILL at the persisted `started` and `completed` boundaries preserved the
corresponding unconfirmed and completed cask states for read-only inspection.
