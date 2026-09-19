# brew-cooldown

Conservative Homebrew upgrades with configurable release-age delays and
expedited updates for verified security fixes.

**Status: experimental formula and cask upgrades.** Install from a checkout;
there is no packaged release yet.
The checkout's [commands](docs/command-planning.md) evaluate a Brewfile or
installed scope and execute eligible formula and cask components on the validated
Homebrew runtime. Its installed-artifact identity limitation is documented there.
`recover` inspects unfinished upgrades and prints repair choices; see
[recovery](docs/execution-recovery.md).
Historical installation and an ordinary post-install hook work in a disposable
VM. The [boundary experiments](docs/installer-boundaries.md) document Homebrew
locking limitations. Avoid overlapping package-changing Homebrew commands;
detected drift will be reported with recovery commands for you to review.
The behavior and command examples below describe the checkout. Read the
[system design](docs/design.md) for the architecture and the
[installer experiment](docs/installer-proof.md) for executable feasibility
work and its remaining limitations.

## Why

You want to keep your tools current without being among the first people to
install every release. Routine updates can wait for early adopters to discover
regressions or compromised releases. A confirmed fix for a vulnerability in
something you already have installed deserves a faster path.

`brew-cooldown` brings a Dependabot-style adoption policy to Homebrew-managed
software on a machine. It is intended for developer workstations and persistent
build machines where unattended upgrades should be deliberate and explainable.

A delay gives problems time to become visible. It does not certify a release
as safe, and keeping an old vulnerable version has risks of its own.

New releases must not keep pushing an upgrade into the future. Each candidate
has its own eligibility date, and a newer release does not reset an older
candidate's clock.

## Usage

Follow [checkout installation](docs/scheduled-adoption.md#checkout-installation)
to put the command on `PATH` and prepare its prerequisites.

Preview upgrades for the installed packages listed in a Brewfile and their
required runtime dependencies:

```sh
brew-cooldown plan --brewfile ./Brewfile
```

Apply the upgrades that qualify under the configured policy:

```sh
brew-cooldown upgrade --brewfile ./Brewfile
```

Inspect a package's decision or export a plan for automation:

```sh
brew-cooldown explain python@3.14 --brewfile ./Brewfile
brew-cooldown plan --brewfile ./Brewfile --json
```

An explicit `--installed` option selects all installed packages instead
of a Brewfile. A Brewfile defines upgrade scope, not installation
of missing entries or removal of unlisted packages.

Planning leaves installed packages and pins unchanged. Applying refreshes and
revalidates the decision before invoking Homebrew; an earlier plan
does not authorize an unchecked replacement candidate.

## Adoption policy

The default cooldowns are:

- Patch releases: 14 days.
- Minor releases: 21 days.
- Major releases: 60 days.
- Versions that cannot be reliably classified: 14 days.

These are configurable globally and per package. Explicit user pins
remain authoritative, including when a security fix is available.

The clock follows the candidate release, not the date you first ran the
tool. Package explanations show the native installed version and candidate
decisions, including available age evidence and eligibility times. A changed
Homebrew package revision needs its own age assessment; an old upstream
version alone does not establish the age of a newly changed package.

When publication dates are unavailable but the exact package identity can be
verified, the full cooldown starts at its first verified observation.
Unverifiable package identity blocks the upgrade. A missing date does not count
as an old release or, by itself, cause a permanent wait.

## Make progress without chasing the latest release

The selection rule is the newest eligible version with a compatible,
eligible dependency set, even when a newer version is still cooling down.
Versions already installed are never downgraded to satisfy that rule.

For example, with a patch cooldown of 14 days:

- Day 0: version 1.2.1 is released; it becomes eligible on day 14.
- Day 7: version 1.2.2 is released; it becomes eligible on day 21.
- Day 14: install 1.2.1 if its dependencies and security checks qualify.
- Day 21: install 1.2.2 if it qualifies, regardless of newer releases.

If several versions qualify when a run starts, choose the newest compatible
one rather than installing each intervening release. Dependency selection
considers eligible historical versions too, so a fresh dependency release
does not automatically block an otherwise usable upgrade.

The tool recovers exact candidates, dependency metadata, and installation
artifacts from Homebrew's history and registry. It reuses Homebrew's
caches instead of maintaining a separate release database or package archive.
Its own durable state is limited to fallback observation times, clock
validation, and the journal needed to reconcile an interrupted upgrade.
Current security evidence is checked before installation; an
earlier eligibility decision does not preserve approval for a release later
found to be compromised.

Routine release churn must not cause indefinite deferral. Genuine blockers
remain possible: an explicit pin, a withdrawn download, incompatible
dependencies, or no acceptable release. Those are reported with a reason
and the action needed to make progress. A maximum-wait timer never
silently authorizes a release that has not completed its own cooldown.

## Security fixes

A candidate can bypass its cooldown only when supported advisory evidence
establishes that the installed package is affected and the candidate fixes the
identified vulnerability. An advisory affecting the installed version does
not, by itself, make the latest version eligible.

The tool uses Homebrew's vulnerability information and
package identities where they provide that evidence. Coverage is
reported explicitly. Missing, stale, or inconclusive security data does not
authorize a bypass or produce a claim that a package is safe; an otherwise
eligible routine update can still proceed under the normal age policy.

A candidate known to remain affected by a reported vulnerability is held
and explained. Pins and dependency constraints can also prevent a security
update, and appear in the result rather than being silently overridden.

## Dependencies and scope

An eligible top-level package is not enough: the packages Homebrew must install
or upgrade with it also need to satisfy the policy. If a required dependency
is too young, pinned incompatibly, or cannot be evaluated, the affected upgrade
is held. A security exception for one package does not automatically
waive the policy for all of its dependencies.

The executor supports bottled `homebrew/core` formulae on Apple
Silicon macOS at `/opt/homebrew`. Cask execution supports the native binary and
generated-completion artifacts used by Codex. Third-party taps and other platforms
are reported as unsupported until their adapters meet the same requirements.
They remain part of the intended product scope. Unrelated installed packages
stay outside a Brewfile run, but their dependency requirements still
constrain changes to shared libraries.

## Automation and visibility

The tool runs as a command under an existing scheduler, without a hosted
service or a background daemon. Frequent checks let verified security
fixes become eligible promptly while ordinary releases continue to wait.

Human-readable and JSON results distinguish upgrades, cooldown holds,
pins, security exceptions, missing evidence, and execution failures. A failed
Homebrew command is reported as a failure. A package that keeps getting
deferred remains visible on subsequent runs.

## Homebrew integration and boundaries

Selecting older eligible releases is a core design requirement. A constrained
Homebrew adapter installs exact official bottles under their original
package identities, with every dependency operation bound to the evaluated
plan. The [disposable-VM experiments](docs/installer-proof.md) establish this
boundary for the tested core formulae and runtime. The project does not
silently fall back to checking only the
latest release when historical installation is unavailable.

The policy applies only to upgrades performed through `brew-cooldown`.
Manual `brew upgrade` commands, application self-updaters, and updates to
Homebrew itself remain outside its control. It does not provide
transactional upgrades or automatic rollback.

## Design and implementation

- [System design](docs/design.md): policy, upstream data ownership, dependency
  selection, command behavior, and interrupted-operation recovery.
- [Homebrew integration](docs/homebrew-integration.md): inspected capabilities,
  exact installation strategy, security evidence, and adapter boundaries.
- [Verification](docs/verification.md): feasibility checks and implementation
  order, including progress through frequent root and dependency releases.
- [Installer experiment](docs/installer-proof.md): reproducible historical
  bottle installation in an expendable macOS VM.
- [Boundary experiments](docs/installer-boundaries.md): native post-install
  workers, shared consumers and accepted concurrency limitations.
- [Cask execution](docs/cask-execution.md): historical native installation
  evidence and the cask adapter design.
- [Execution and recovery](docs/execution-recovery.md): drift reporting,
  interrupted upgrades and text-only recovery commands.
- [Policy core](docs/policy-core.md): deterministic eligibility, fallback clocks
  and dependency selection, separate from installation.
- [Security evidence](docs/security-evidence.md): native advisory refresh,
  exact-version assessment and evidence required for expedited adoption.
- [Registry discovery](docs/registry-discovery.md): upstream historical tags,
  immutable manifest identity and platform publication evidence.
- [Command planning](docs/command-planning.md): configuration, Brewfile scope,
  active inventory and the experimental commands.
- [Scheduled adoption](docs/scheduled-adoption.md): checkout installation,
  workload qualification and the scheduler contract.

Historical installation remains part of the acceptance criteria. A latest-only
updater does not satisfy the design.

Distribution through Homebrew is a goal for a future release. This project is
independent of Homebrew and does not imply endorsement or acceptance into its
package repositories.

## Contributing, security and license

[CONTRIBUTING.md](CONTRIBUTING.md) describes the checks and conventions. Report
vulnerabilities privately as described in [SECURITY.md](SECURITY.md).
`brew-cooldown` is released under the [MIT License](LICENSE).
