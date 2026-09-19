# System design

Status: architecture for implementation. The
[installer experiment](installer-proof.md) exercises the initial execution
boundary. The installation adapter must pass the feasibility checks in
[Homebrew integration](homebrew-integration.md) before this design can become
an unattended updater.

The [boundary experiments](installer-boundaries.md) demonstrate a native
post-install hook and establish that package locks do not exclude every
concurrent Homebrew mutation. Avoid overlapping package-changing commands.
The adapter detects drift where possible and reports recovery choices; it does
not enforce exclusive ownership of the prefix.

## Decisions

Build a deterministic planner and a constrained Homebrew executor over
Homebrew's existing release history. Discover superseded candidates upstream;
do not maintain a separate release database, metadata mirror, or bottle
archive. Select eligible versions and compatible dependencies together. A new
release adds an option; it never disqualifies an older option merely by
superseding it.

Use Ruby for the product, running in Homebrew's Ruby environment. Homebrew
already owns formula evaluation, version ordering, platform selection, and
installation. Reimplementing those in a different language would introduce
disagreement at the most consequential boundary. Keep Homebrew internals in an
adapter; the policy and planning core takes ordinary typed domain records and
an injected UTC timestamp. A formula-managed Python or Ruby interpreter must
not be needed while its own package is being upgraded.

Keep the policy and planner separate from the Homebrew adapter within the Ruby
product. A second language would add a serialization contract, runtime packaging
and cross-process failure handling without simplifying the native installer.
Introduce that boundary only if a concrete benefit warrants its maintenance.

Handwritten source and test files should generally stay below 800 lines.
Growing files call for a review of responsibilities and cohesive collaborators,
not arbitrary text splitting. Apply this during development and review; no
repository-specific enforcement framework is required.

The command is `brew-cooldown`, also invocable as `brew cooldown` through
Homebrew's external-command discovery. An executable launcher only enters the
Homebrew Ruby environment and forwards arguments. There is no service,
privileged helper, hosted database, telemetry, or private infrastructure.

The first installation adapter targets bottled `homebrew/core` formulae on
Apple Silicon macOS at `/opt/homebrew`. Discovery and planning explicitly report
casks, third-party taps, source-only packages, and unsupported platforms.
They are not silently omitted or advertised as executable support. Cask and
tap adapters must meet the same contracts before enabling their upgrade paths.
This narrows initial execution, not the requirement to select historical
eligible versions.

## Command contract

- `plan --brewfile PATH` refreshes metadata and prints a plan for installed
  entries and their required runtime dependencies.
- `plan --installed` selects all installed formulae and casks as roots.
- `upgrade` accepts the same scope options, computes a fresh plan, stages its
  artifacts, revalidates it, and applies independent eligible components.
- `upgrade --security-only` permits only components needed to fix a verified
  installed vulnerability. Required dependencies still need their own normal
  eligibility or security exception.
- `explain PACKAGE` shows candidate decisions and dependency blockers using
  the configured scope; a package outside that scope is reported as such.
- `--json` produces a versioned result on stdout. Diagnostics and Homebrew
  output go to stderr. Human output uses the same result records.

An explicit scope option overrides configured scope. Without either, reject
the invocation rather than guess all installed packages. Homebrew's Brewfile
reader determines entries and conditions; do not parse Ruby with regular
expressions or run `brew bundle install`. Brewfile installation hooks are not
invoked. Brewfiles themselves remain trusted executable configuration.
Non-Homebrew entries are reported as outside this tool's scope. Empty scope
is an empty plan. Missing root packages are reported and not installed.

Planning may refresh Homebrew's normal caches and record fallback observation
times. It does not change installed packages, pins, taps, or service state.
There is no saved-plan execution command initially: JSON plans are review
artifacts, not scripts or authorization tokens.

Exit status is `0` for a completed assessment or execution with only expected
waits, intentional pins, and successful changes; `1` for invalid input,
incomplete assessment, unsupported selected packages, operational blockers, or
execution failure. JSON distinguishes those conditions. Pending cooldowns do
not make routine scheduled runs fail. A known vulnerable installation without
an actionable fix is an operational blocker, including when pinned.

## Configuration

Use JSON at `${XDG_CONFIG_HOME:-~/.config}/brew-cooldown/config.json`.
Override it with `--config PATH`. Reject unknown keys and invalid values.
Package overrides use identities such as `formula:homebrew/core/python@3.14`.
Ambiguous bare-name overrides are errors. CLI input can use an unambiguous
alias, resolved once and recorded with its canonical identity.

The policy fields are `cooldown.patch_days`, `cooldown.minor_days`,
`cooldown.major_days`, and `cooldown.default_days`, initially 14, 21, 60,
and 14. The `packages` map can override those fields per identity. Values are
nonnegative integer days. Existing Homebrew pins always win; overrides never
unpin a package. There is no automatic maximum-wait bypass.

Scope is either `scope.brewfile` or `scope.installed`, never both. Resolve a
configured relative Brewfile path against the configuration directory, and a
CLI path against the working directory. Scheduling stays with the caller.
Daily ordinary runs are the recommended starting point: cooldowns already
govern routine adoption. A weekly routine schedule can be paired with daily
`upgrade --security-only` runs.

## Identity and data ownership

Distinguish these records rather than passing loosely shaped dictionaries:

- `PackageId`: kind, canonical tap identity, and token. Formulae and casks
  cannot collide. Alias or tap migrations require verified mapping.
- `Candidate`: package identity, upstream version, Homebrew version scheme,
  revision, bottle rebuild, platform tag, exact recipe digest, registry
  manifest digest, artifact digest, source provenance, and dependency data.
- `Observation`: candidate identity, evidence source, publication evidence,
  first verified observation where needed, and current source validation.
- `InstalledPackage`: active keg or cask, receipt and recipe identity, pins,
  dependency records, and linkage information. Unlinked old kegs are not
  interchangeable with the active installation.
- `Decision`: selected or rejected candidate, reason code, evidence references,
  eligibility timestamp, security status, and dependency explanation.
- `Plan`: inventory fingerprint, configuration digest, upstream snapshot IDs,
  advisory digest, evaluated timestamp, ordered components, and exact effects.

Derive candidate identity from a canonical serialization of the identity
fields and SHA-256. A version string alone is never an artifact identity.
The same version with changed recipe or bottle bytes is a different candidate.
A moved registry tag cannot inherit the previous digest's observation clock.

Upstream owns the datasets:

- Homebrew receipts and pins describe installed state.
- Official tap Git history supplies historical recipe and publication
  evidence; query it by package path rather than cloning a private mirror.
- Homebrew's OCI registry supplies historical bottle metadata and artifacts,
  including embedded recipes when present. A dangling source-commit pointer
  does not invalidate a verifiable embedded recipe.
- Homebrew's reviewed advisory feed supplies vulnerability records.
- Homebrew's existing caches hold ordinary reusable metadata and downloads.

Installed artifact identity also remains Homebrew-owned. Never create a
supplemental receipt or installation identity database, even for upgrades this
tool performs. An absent installed bottle rebuild remains unknown; an embedded
recipe's default cannot fill that gap. Ordinary version and revision advances
can still qualify. A rebuild-only candidate whose advancement cannot be proved
gets an explicit diagnostic, while independent eligible work proceeds.

The normalized candidate graph exists in memory for one invocation. Historical
queries are scoped to selected roots and discovered dependencies, paginated,
and conditional where upstream supports it. Use Homebrew's existing fetch and
cache facilities where they preserve source identity and freshness. Do not
create a second cache hierarchy or a background indexing job. Partial history
is reported as incomplete, not as proof that no eligible release exists.
Proven eligible candidates remain usable if additional discovery fails, but
the result must not claim exhaustive newest-version selection.

Keep only tool-owned operational state under
`${XDG_STATE_HOME:-~/.local/state}/brew-cooldown`, namespaced by the canonical
Homebrew prefix:

- A compact ledger mapping candidate digest to first verified observation,
  only when reliable publication dates are unavailable. It contains no
  recipes, dependency graph, advisory copy, or package archive.
- An unfinished-operation journal containing the exact selected identities,
  evidence references, expected effects, and completed steps needed to
  reconcile an interrupted execution.
- A last-seen UTC timestamp for detecting clock regression.

Update these small versioned JSON files atomically under the tool lock. Reject
unsupported schemas without deleting them. Remove the active journal after
successful reconciliation; emit the final result to the caller for retention
if desired. Do not maintain an installation-history database. Observation
entries older than the installed baseline can be removed after successful
reconciliation. Retain still-relevant fallback clocks across runs; their loss
restarts that conservative wait rather than making a release look older.

Download candidate artifacts only when planning or execution needs them, into
Homebrew's normal cache. Before mutation, reserve private temporary staging
for the component, using hard links to verified cache objects where safe or a
temporary copy otherwise.
An active journal owns that staging until completion or reconciliation. Check
space before starting and report the required bytes on failure. Never change
global Homebrew cache or cleanup policy. There is no proactive release archive
and no separate retention mechanism. Historical availability is supported by
the observed downloads in [Homebrew integration](homebrew-integration.md).
If a download is unavailable, reject that candidate for this invocation and
try the next compatible eligible candidate. A transient network failure is not
a permanent withdrawal; only report an artifact blocker when no usable
candidate remains. Never substitute a younger release to hide a download error.

## Release age

Measure elapsed UTC duration, with one day equal to 86400 seconds. Equality
at the eligibility timestamp qualifies. Time is supplied to the policy core;
local calendar dates and daylight-saving transitions do not affect eligibility.

For a bottle with an embedded recipe, the authenticated artifact binds both
the recipe and the payload; use that platform artifact's publication evidence.
When a separate recipe is required, use the later of its publication evidence
and the artifact's. An upstream release date alone is insufficient. Prefer
Homebrew source history and registry metadata tied to the exact digests,
under the trust rules in [Homebrew integration](homebrew-integration.md).

If either publication time is unavailable, use the first successful verified
observation of the recipe and authenticated artifact digest as the conservative
origin. This records how long that exact candidate identity has been known; it
does not assert when it was originally published or require downloading every
candidate. Verify the actual artifact checksum when staging it for execution.
Unverifiable identity or a missing authenticated digest blocks the observation
clock. Conflicting or future-dated evidence is reported for correction.
Wall-clock regression relative to durable state blocks execution until the
clock is corrected.

Classify an upgrade against the active installed version. Use major/minor/patch
classification only for stable semantic versions with a nonzero major and an
unchanged Homebrew version scheme. Pre-release, pre-1.0, non-semantic versions,
and version-scheme changes take the default delay. Same-version revision or
bottle rebuild changes also take the default delay. A newly required dependency
without an installed baseline takes the default delay.

Homebrew's version ordering determines upgrade direction; semantic
classification only chooses the delay. Never downgrade an active package.
An installed package need not retroactively complete a cooldown to remain in
place. Eligibility for a fixed candidate and fixed baseline cannot move later
merely because another candidate was published. A policy change or new
security evidence can change the decision and must be explained.

## Selection and dependency resolution

Build a finite domain for each relevant package: its active installed version
plus verified candidate versions. Remove candidates that fail platform,
identity, age, pin, or security policy. Include required runtime dependencies
even when absent, because installing them may be necessary for an upgrade.
Exclude build-only dependencies because the initial executor never compiles.

Read compatibility from the exact bottle and recipe, using Homebrew's version
and dependency semantics. A bare dependency name is not a promise of binary
compatibility. Exact recorded dependency versions are admissible; replacing
them with another version requires positive compatibility evidence supported
by the adapter. A minimum version by itself supplies no upper ABI guarantee.

Read reverse dependencies across the entire installed prefix. Packages outside
scope are fixed constraints, not automatic additional upgrade targets. If a
shared dependency change needs an out-of-scope dependent rebuilt or upgraded,
report the dependent and suggest expanding scope. Never silently disable
linkage repair and assume those consumers will continue working.

Resolve connected components of the dependency and reverse-dependency graph
independently. Unrelated blocked components do not delay working components.
Within a component, use deterministic backtracking with constraint propagation
and memoized rejected assignments. Do not introduce a general package-manager
service or invent a different interpretation of Homebrew dependencies.

The preference order is: components with verified security fixes, then roots
whose eligible upgrade has waited longest, then canonical package identity.
For each prioritized root, prefer its newest feasible eligible candidate.
Prefer keeping dependencies unchanged where they satisfy the solution; then
prefer eligible upgrades. Retain alternatives and backtrack on conflicts.
Derive a root's oldest outstanding eligibility timestamp from the available
historical candidates on each run, using the small fallback observation ledger
only when needed. New publications do not change older candidates' timestamps.

The objective is lexicographic in that order, not a claim that every root can
always get its independently newest version. The explanation identifies any
shared dependency tradeoff. After a root advances, remaining newer eligible
versions retain their own eligibility times for the next run.

Limit search by a deterministic assignment budget, initially 100000 explored
assignments per component, configurable as `solver.max_assignments`. Exhaustion
is `resolution_limit`, not `no_compatible_solution`. Do not execute a partially
resolved component. Increase the budget or improve domain pruning; do not
silently waive compatibility checks.

## Security exceptions

Use the reviewed Homebrew advisory feed for exact Homebrew formula identities.
Reuse Homebrew's range evaluation through the adapter. Do not infer matches
from product names, changelog text, or a CVE search. Formula coverage does not
establish cask coverage. The data source and its limitations are recorded in
[Homebrew integration](homebrew-integration.md).

Authorize an age exception only when a non-withdrawn supported record proves
that the active installed package is affected and the exact candidate crosses
an explicit fixed boundary for that same advisory. A range ending without an
explicit fix is insufficient. Revision fixes use the full Homebrew package
version. A patch-only claim also requires the selected recipe and artifact to
contain that patch; a patch in today's recipe says nothing about an old bottle.

Require a successful feed validation during the current upgrade invocation
before any exception. An HTTP 304 counts only with the matching intact cached
payload. A stale-cache fallback does not. Refresh again before a component if
the validation is more than one hour old. Feed access failure disables the
exception path and is visible; ordinary age-qualified upgrades can proceed
with security status `unknown`, subject to already known adverse evidence.

Exclude candidates that supported evidence identifies as affected by any
non-withdrawn advisory. On fetch failure, use Homebrew's last validated cached
feed as adverse evidence, never as authority for a cooldown bypass. Unknown
coverage is not a clean bill of health. Unsupported or ambiguous ranges are
`unknown`, never automatic proof of a fix. There is no independent advisory
history: if Homebrew's cache is unavailable too, report unavailable coverage.

Exceptions are per package, not per dependency component. A new dependency
without an affected installed version cannot claim an installed-vulnerability
exception. If a fix needs a young dependency without its own exception, report
that exact blocker. Do not force the update or suppress its urgency.

## Applying a plan

Acquire a prefix-scoped exclusive tool lock, then read inventory and pins.
Refresh evidence, resolve, and download every required artifact for a component
before its first mutation. Verify digests and the adapter's provenance checks.
Re-read inventory, pins, configuration, Homebrew compatibility identity, and
security evidence immediately before execution. If assumptions changed,
replan; never substitute a different candidate inside an old plan.

The executor runs a locked candidate map through Homebrew's installer. All
package resolutions and mutation requests must match that map before they
occur. Dependency installation order comes from the selected graph. Explicit
pins remain untouched. No automatic cleanup, source-build fallback, tap
migration, forced overwrite, or unplanned dependent repair is permitted.

Write and flush an execution journal before each package operation; record
its result after inspecting receipts and linkage. Stop the component on a
failure and report completed, failed, and unstarted operations. Inspect other
components' assumptions again before continuing. An interrupted operation is
`needs_reconciliation`; the next invocation compares actual state with the
journal before doing further work. Never replay an installer blindly.

There is no whole-prefix transaction or automatic rollback. Keep old kegs and
the evidence needed for manual recovery. A successful subprocess exit alone
does not establish a successful upgrade: compare actual versions, receipts,
pins, and affected linkage with the planned outcome. Service hooks may change
service state during installation and belong in the visible plan.

The tool lock coordinates its own invocations. It cannot stop arbitrary manual
Homebrew commands or application self-updaters. The adapter must use Homebrew
package locks as well, acquired before its own mutations. Other Homebrew
commands can still change pins or temporarily remove a keg despite those
locks. Avoid overlapping mutations; this is an operating recommendation, not
an enforced exclusive-writer requirement. An external race can cause a partial
failure. Inventory and receipt comparisons detect drift where possible and do
not make those races atomic.

On drift or failure, print the expected and observed state, completed work,
and concrete commands the user can choose to run. Where the receipts support
it, offer relinking the retained old keg and repairing forward with native
Homebrew. Explain when a command adopts Homebrew's current release outside the
cooldown policy, or cannot reverse a hook's configuration changes. Commands
are text only: no automatic rollback, unpinning or repair outside the plan.

Attempt available policy-compliant candidates and independent components.
An unavailable artifact leads to another candidate; a drifted plan is recomputed
before mutation where possible. If no valid action remains, return the precise
error and recovery guidance instead of a generic refusal. Cooldowns, explicit
pins, verified identity and known adverse security evidence still govern the
attempts.

## Progress contract

If a compatible candidate set remains available and acceptable, scheduled runs
continue, and the machine's pins and scope allow it, newer publications alone
cannot prevent that set from being installed after its cooldown. The planner
must demonstrate this with daily root and dependency releases.

This is not an unconditional update deadline. Withdrawn artifacts, changed
security evidence, incompatible installed consumers, explicit pins, offline
sources, or unsupported installation behavior can prevent progress. Results
must distinguish a normal wait with an eligibility timestamp from a blocker
with a concrete remedy. See [verification](verification.md) for the evidence
required before shipping.
