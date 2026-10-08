# Trusted tap release archives

Third-party formula execution is opt-in through `trusted_taps`, an array of
canonical tap names, for example `"trusted_taps": ["openai/tools"]`. Trust grants
permission to evaluate that tap's historical Ruby recipes and run their native
installation hooks. It does not waive cooldown, pins, dependency assessment,
checksums, platform requirements, current withdrawals or recovery. Existing
installed recipes are already local executable Homebrew state; retaining a pin
requires no historical discovery or installer support.

The adapter reads the conventional GitHub repository for the named tap
(`openai/tools` maps to `openai/homebrew-tools`). Custom remotes and non-GitHub
taps are outside this contract. It anchors history to the repository's current
default-branch commit and verifies each recipe's Git blob before native Ruby
evaluation. Formula paths under `Formula/` are resolved from that commit's tree;
ambiguous paths and truncated trees fail closed. No tap is installed or updated.

Supported recipes install checksum-bound, versioned GitHub release archives
containing macOS binaries. Build dependencies, additional resources, patches,
options, fetch hooks, bottles and binary linkage into Homebrew are outside this
adapter. Those cases remain explicit failures, rather than falling through to
ordinary `brew upgrade`. Execution copies the selected recipe and archive into
sandbox-protected private
snapshots; native receipts retain the selected tap and source commit.
Trusted install code is not statically interpreted:
Homebrew evaluates the exact recipe and runs its hooks in the native sandbox.
Trusting a tap therefore includes trusting its installation code.

Each candidate identity includes canonical package, native build, platform,
recipe digest, release URL and archive checksum. Publication age uses the later
of the recipe commit and the matching release asset's publication/update time.
An available vendor digest must match the recipe checksum. Missing reliable
publication dates use the existing verified observation ledger; mismatched
identity and future evidence never become an old release. Historical candidates
remain separate even when a newer release is cooling.

Release binaries may depend on other packages at runtime, but do not establish
bottle ABI cohorts. Archive inspection rejects Homebrew library linkage. Native
installed binary inspection distinguishes runtime-only retained consumers from
consumers requiring exact build evidence. Dependencies enter the existing graph
and keep their own trust, pin and cooldown decisions.

## Guard and identity audit

| Boundary | Release archive path |
| --- | --- |
| Scope and trust | Canonical configured tap; pins retained before adapter checks |
| Source provenance | Current GitHub head, path-scoped history and verified blob |
| Current bound | Native build ordering and current disabled state |
| Artifact authority | Exact release URL and recipe SHA-256; vendor digest checked when present |
| Age | Later recipe/asset evidence or verified observation fallback |
| Dependency graph | Native runtime edges; every replacement independently evaluated |
| Execution runtime | Existing qualified Homebrew commit and Apple Silicon prefix checks |
| Resolver | Existing exact map in coordinator and sandbox workers |
| Installation | Release-only branch in installer guard; Core keeps bottle-only guard |
| Hooks | Native sandbox with exact recipe map; no hook-owned installer |
| Pins and drift | Existing inventory fingerprint and before-install revalidation |
| Journal and recovery | Existing package operation boundaries, receipts and link checks |

JSON and native Homebrew evaluators parse inputs; no Ruby text parser is added.
URI parsing selects versioned GitHub release URLs. Unknown field shapes, missing
sources, deleted recipes/assets, duplicate identities and truncated history
remain errors. The candidate key excludes the source commit identifier because
an unchanged recipe and artifact retain their identity across unrelated tap
commits; changed recipe or artifact bytes always produce a new key. Publication
evidence is re-read before execution. Selection paths are restricted to a unique
regular Ruby formula below `Formula/`, never a symlink or a cask.

## Qualification

The trusted-tap track in `script/qualify` runs only in a disposable Apple Silicon
macOS VM. It exercises historical Tart and softnet installation, candidate age
and dependency selection, native receipts and links, pins, trust refusal, and
interruption followed by explicit recovery. The track is evidence only after
its `qualified` run succeeds; workstation unit tests do not establish native
installation behavior.
