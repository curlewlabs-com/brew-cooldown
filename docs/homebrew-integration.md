# Homebrew integration

Status: selected integration design with an unproven execution adapter. This
document separates observed Homebrew capabilities from the behavior we need
to establish in disposable environments. No host packages were changed during
the design investigation.

## Findings that shape the design

Homebrew documents a Ruby extension mechanism with access to its internal
libraries, but explicitly does not guarantee compatibility for those APIs.
Use a Ruby product with a narrow adapter and test each supported Homebrew
release. See [external commands](https://docs.brew.sh/External-Commands).

Historical formula extraction is supported, but the extracted formula becomes
the caller's maintenance responsibility. The inspected `extract` implementation
renames the formula and removes its bottle block. It is therefore not our
installation strategy: that would change package identity and commonly require
source builds. See [version support](https://docs.brew.sh/Versions) and
[the inspected extractor][extract].

Homebrew can load a formula from a local bottle, but the inspected loader can
fall back to another formula when embedded metadata is unusable. The installer
also skips its normal bottle attestation path for local bottle files. Invoking
`brew install FILE` alone does not meet our exact-candidate or trust contract.
See [the bottle loader][formulary] and [the installer][installer].

An API mirror is not a closed candidate source: `HOMEBREW_API_DOMAIN` explicitly
falls back to Homebrew's default API when unavailable. Signed API data also
cannot simply be rewritten to contain our chosen historical versions. Do not
use a synthetic API mirror or rewrite the user's taps or shared API cache to
force historical selection. Ordinary Homebrew cache refresh is allowed.
See [environment configuration][env] and [API verification][api].

These observations were made against Homebrew commit
`edb70f031e4170c780799633a1226ff73e1077f4`. They establish what was inspected,
not a supported-version declaration. Compatibility support requires the tests
in [verification](verification.md).

## Historical discovery without a private dataset

Discover current core identities from Homebrew's official metadata and source
paths. Enumerate superseded bottles through registry tags and official package
history; fetch OCI manifests by digest after resolving discovery references.
Use the recipe embedded in the verified bottle when available. Otherwise
recover the corresponding recipe from reachable official Git history, with
evidence binding it to that artifact. Do not assume every registry annotation
names a reachable source commit. Keep the source repository and commit,
recipe content digest, platform manifest digest, bottle
digest, revision, rebuild, version scheme, and dependency metadata together in
the invocation's candidate records. Upstream retains history; these records
are not copied into a durable product database.

Read-only registry inspection on 2026-09-18 found historical `jq` manifests for
1.8.0 and 1.8.1 while the formula API reported 1.8.2. The 1.8.1 Apple Silicon
Sequoia manifest referenced source commit
`339fb67352d7fe8c4836ab03200dda21e9b648eb`, bottle SHA-256
`d7bce557bb82addd6cf01b8bb758d373ee11cb6671e4d7b1dc2a2c89816bcc32`, and an
`oniguruma` runtime dependency at 6.9.10. This demonstrates historical metadata
availability for that example, not successful installation. The annotated
source commit could not be resolved through GitHub's commit API or raw-file
endpoint. The actual bottle did contain `jq/1.8.1/.brew/jq.rb`, readable without
extracting or executing it. Its digest was
`aa15039dc16a5e28c9afd468091147cfd886791cf844e575a276293bc29f7ce3`.

Additional read-only checks that day downloaded the actual `ripgrep` 13.0.0
bottle for Mojave, created 2021-06-12, and `wget` 1.21.4 for Big Sur, created
2023-05-11. Both artifact SHA-256 digests matched their registry manifests.
Their annotated source-file URLs did not resolve either. A probe for the bare
`jq:1.6` registry tag returned 404. Without evidence that this exact tag
existed, that is not evidence of deletion.

These observations support using Homebrew's retained bottles directly. The
investigation did not establish routine remote expiration or a contractual
retention promise. Neither uncertainty warrants a private archive. Treat an
unavailable artifact as a candidate-level download failure and try another
eligible compatible candidate. Local `brew cleanup` is separate from remote
registry retention. Cask download availability belongs to the application's
publisher and cannot be inferred from Homebrew bottle retention.

Registry annotations and formula history are evidence, not interchangeable
clocks. Use the platform manifest's creation time for an authenticated bottle
and its embedded recipe. A separately recovered recipe also needs publication
evidence; do not use a source archive's modification time.
Dates must bind to the candidate's exact bytes. A registry tag, filename, or
upstream release date without that binding cannot authorize an age decision.
An unavailable reliable timestamp invokes the observation-based wait in the
[system design](design.md#release-age).

Trust comes from the official source and registry provenance, and applicable
Homebrew bottle attestation verification, not from a hash alone. Reuse the
verification Homebrew requires for the selected bottle class; using a local
path must not disable it. Include verification results with their source and
verifier identity in the plan. Conflicting digests, unexpected repository
identity, or a failed required attestation reject a candidate.

Homebrew and its official publishers remain in the trust boundary. This tool
does not defend against a compromised Homebrew installation forging its own
metadata, or certify a release safe because its publisher supplied an old
timestamp. First-observation waiting is the fallback when publication
evidence cannot be established, not permission to trust unverified bytes.

Enumerate versions newer than the installed baseline using registry tags and
reachable official history; when the baseline is absent, inspect available
candidate history. Resolve dependency histories on demand. Use normal
Homebrew cache facilities where available and honor upstream rate limits.
Pagination belongs to the current invocation, not a persistent indexer. On
interruption, recompute from upstream and existing caches. There is no private
mirror or registry-retention guarantee. Optional user-provided GitHub
credentials are read from the environment, never written to plans or logs.

## Adapter interface

Expose domain operations to the pure planning core:

- `inventory`: installed identities, active receipts, pins, and consumers.
- `read_scope`: evaluated Brewfile formula and cask roots.
- `discover`: normalized candidates and evidence with completeness status.
- `compare`: Homebrew version ordering and supported dependency compatibility.
- `assess_security`: explicit affected/fixed/unknown results for exact versions.
- `preflight`: operations, prerequisites, hooks, and artifact verification.
- `execute`: apply only the supplied candidate map and return observed effects.

Every call either returns its declared record or a structured error with the
operation and package identity. An empty list is never a substitute for failed
dependency discovery. Do not scrape warning text to infer completeness.

Use Homebrew's formula evaluator on exact trusted recipe bytes. Do not rewrite
Ruby recipe text with heuristic substitutions. A process-local resolver maps
canonical package identities to the selected formula objects. Installed
packages retained unchanged also have explicit entries. An unknown identity,
alias migration, alternative recipe load, or version substitution is rejected.

The adapter may use internal loader and installer hooks, but all such hooks
live in the adapter and in a fresh worker process. No modification of the
installed Homebrew tree, persistent global monkey-patch, or namespace-changing
local tap is allowed. Loading old Ruby recipes executes trusted recipe code;
this boundary is not a sandbox for arbitrary third-party code.

Maintain an explicit compatibility list of Homebrew releases and fingerprints
of the internal methods the adapter relies on. Verify it before any mutation;
an unrecognized or locally changed implementation permits diagnosis and
planning where possible, but not execution. A new compatible release is a
tested adapter update, not a version-range guess. Homebrew HEAD is unsupported.

## Exact installation

Download promising eligible bottles only as needed to finish metadata
resolution when embedded recipes are required. Use Homebrew's cache, and
include these downloads in planning output. A metadata-only pass cannot
claim full installation feasibility when required recipe data is absent.

Materialize every selected recipe and bottle in private staging. Build formula
objects with their original names, taps, and package versions; preserve normal
Cellar and `opt` identities. Do not rename `foo` to `foo@oldversion` and call
that an upgrade of the existing package.

Construct the selected dependency graph before invoking an installer. Bind
every root and dependency lookup to the map for the entire operation, including
post-install subprocesses. A lookup returning a current API formula or missing
bottle metadata is a hard error. Populate and verify the exact runtime
dependency metadata needed by Homebrew; a local bottle path must not cause a
fallback to unversioned dependency declarations.

The executor must check each requested install, upgrade, reinstall, migration,
and source build against the plan before that operation starts. Directly
passing `ignore_dependencies` is not enforcement. If Homebrew cannot be
constrained at that boundary, this adapter design has failed its feasibility
gate; do not replace it with post-hoc detection and ship anyway.

Retain Homebrew's platform checks, conflict checks, package locks, trust
checks, relocation, receipt writing, and post-install behavior. Disable
automatic metadata refresh and cleanup for the operation. Use no implicit
source builds or forced bottle compatibility. Recheck reverse consumers and
post-install effects; automatic dependent upgrades outside the plan are
forbidden. If suppressing Homebrew's dependent repair is necessary, demonstrate
that the selected graph needs no such repair before allowing execution.

Recipes with recursive package-manager invocation, unbounded external install
hooks, or unsupported service behavior cannot be enabled until the adapter can
enforce the same map across those operations. The initial prototype must
exercise representative ordinary post-install hooks before its scope is
declared viable; an adapter that only installs trivial leaves is insufficient.

Homebrew's current dependency checks use more than declared package names and
can accept already installed versions according to bottle metadata. The
planner needs stronger evidence before changing a shared dependency: exact
build-version agreement, or positive compatibility metadata plus the relevant
linkage contract. Record the evidence per edge. Do not generalize from a
successful version comparison to arbitrary ABI compatibility. Insufficient
evidence is a reported compatibility blocker.

Historical installer support is the largest implementation risk. If reliable
execution would require a maintained Homebrew fork, a private bottle build
farm, or broad replacement of its dependency engine, return to design review.
Those are different projects and are not implicit in this architecture.

## Security data

Use the [reviewed Homebrew advisory corpus][advisories]. Match the exact
`Homebrew` ecosystem and package, including package revision boundaries.
Invoke Homebrew's range evaluator through the adapter with an explicitly
validated payload, reusing Homebrew's advisory cache rather than maintaining
another advisory database. Do not treat its loader's stale fallback as a
successful refresh, or a formula API summary as a complete historical scan.

`brew vulns` remains useful to users, but an installed scan or a
`--fix-available` result does not prove that our chosen historical candidate
fixes the installed vulnerability. The adapter evaluates the installed and
candidate versions against the same supported record and preserves unknown
results. Cask security bypass is unavailable until an exact identity and
version-aware advisory source is supported.

## Casks and third-party taps

The first plan reports these packages as `unsupported_executor` rather than
silently ignoring them. A future cask adapter must retain exact recipe and
download digests, support historical downloads, honor platform requirements
and pins, and constrain uninstall/install hooks. `version :latest`, mutable
downloads without verified digests, application self-updaters, and privileged
installers cannot inherit formula guarantees.

Third-party taps require explicit trust, canonical source identity, reliable
history, and a verified artifact path. Reuse the same planner and adapter
contract; do not let an unsupported tap fall through to ordinary `brew upgrade`.

[extract]: https://github.com/Homebrew/brew/blob/edb70f031e4170c780799633a1226ff73e1077f4/Library/Homebrew/dev-cmd/extract.rb
[formulary]: https://github.com/Homebrew/brew/blob/edb70f031e4170c780799633a1226ff73e1077f4/Library/Homebrew/formulary.rb
[installer]: https://github.com/Homebrew/brew/blob/edb70f031e4170c780799633a1226ff73e1077f4/Library/Homebrew/formula_installer.rb
[env]: https://github.com/Homebrew/brew/blob/edb70f031e4170c780799633a1226ff73e1077f4/Library/Homebrew/env_config.rb
[api]: https://github.com/Homebrew/brew/blob/edb70f031e4170c780799633a1226ff73e1077f4/Library/Homebrew/api.rb
[advisories]: https://github.com/Homebrew/advisory-database/blob/main/CONTRIBUTING.md
