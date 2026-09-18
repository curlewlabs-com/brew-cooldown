# brew-cooldown

Conservative Homebrew upgrades with configurable release-age delays and
expedited updates for verified security fixes.

**Status: design proposal.** There is no implementation or installable release
yet. The behavior and command examples below describe the proposed tool.

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
would have its own eligibility date, and a newer release would not reset an
older candidate's clock.

## Proposed usage

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
brew-cooldown explain python@3.14
brew-cooldown plan --brewfile ./Brewfile --json
```

An explicit `--installed` option would select all installed packages instead
of a Brewfile. A Brewfile would define upgrade scope, not trigger installation
of missing entries or removal of unlisted packages.

Planning would leave installed packages and pins unchanged. Applying would
refresh and revalidate the decision before invoking Homebrew; an earlier plan
would not authorize an unchecked replacement candidate.

## Adoption policy

The proposed default cooldowns are:

- Patch releases: 14 days.
- Minor releases: 21 days.
- Major releases: 60 days.
- Versions that cannot be reliably classified: 14 days.

These would be configurable globally and per package. Explicit user pins would
remain authoritative, including when a security fix is available.

The clock would follow the candidate release, not the date you first ran the
tool. Each decision would identify the installed version, candidate version,
age evidence, applicable delay, and earliest eligibility time. A changed
Homebrew package revision would need its own age assessment; an old upstream
version alone would not establish the age of a newly changed package.

Missing or ambiguous age evidence would hold the affected upgrade and explain
what could not be established. A missing date would never count as an old
release.

## Make progress without chasing the latest release

The selection rule would be the newest eligible version with a compatible,
eligible dependency set, even when a newer version is still cooling down.
Versions already installed would never be downgraded to satisfy that rule.

For example, with a patch cooldown of 14 days:

- Day 0: version 1.2.1 is released; it becomes eligible on day 14.
- Day 7: version 1.2.2 is released; it becomes eligible on day 21.
- Day 14: install 1.2.1 if its dependencies and security checks qualify.
- Day 21: install 1.2.2 if it qualifies, regardless of newer releases.

If several versions qualify when a run starts, choose the newest compatible
one rather than installing each intervening release. Dependency selection
would consider eligible historical versions too, so a fresh dependency release
would not automatically block an otherwise usable upgrade.

This requires retaining or recovering exact package candidates, their
dependency metadata, and verifiable installation artifacts after they are
superseded. Remembering a version number or its eligibility date is not enough.
Current security evidence would still be checked before installation; an
earlier eligibility decision would not preserve approval for a release later
found to be compromised.

Routine release churn must not cause indefinite deferral. Genuine blockers
would still be possible: an explicit pin, a withdrawn download, incompatible
dependencies, or no acceptable release. Those would be reported with a reason
and the action needed to make progress. A maximum-wait timer would never
silently authorize a release that has not completed its own cooldown.

## Security fixes

A candidate could bypass its cooldown only when supported advisory evidence
establishes that the installed package is affected and the candidate fixes the
identified vulnerability. An advisory affecting the installed version would
not, by itself, make the latest version eligible.

The intended approach is to reuse Homebrew's vulnerability information and
package identities where they provide that evidence. Coverage would be
reported explicitly. Missing, stale, or inconclusive security data would not
authorize a bypass or produce a claim that a package is safe; an otherwise
eligible routine update could still proceed under the normal age policy.

A candidate known to remain affected by a reported vulnerability would be held
and explained. Pins and dependency constraints could also prevent a security
update, and would appear in the result rather than being silently overridden.

## Dependencies and scope

An eligible top-level package is not enough: the packages Homebrew must install
or upgrade with it also need to satisfy the policy. If a required dependency
is too young, pinned incompatibly, or cannot be evaluated, the affected upgrade
would be held. A security exception for one package would not automatically
waive the policy for all of its dependencies.

The intended scope includes formulae, casks, and their required runtime
dependencies. Support would depend on being able to identify and evaluate the
actual candidate. Unsupported packages or sources would be reported as held,
with a reason. Unrelated installed packages would stay outside a Brewfile run.

## Automation and visibility

The tool would run as a command under an existing scheduler, without a hosted
service or a background daemon. Frequent checks would let verified security
fixes become eligible promptly while ordinary releases continue to wait.

Human-readable and JSON results would distinguish upgrades, cooldown holds,
pins, security exceptions, missing evidence, and execution failures. A failed
Homebrew command would be reported as a failure. A package that keeps getting
deferred would remain visible on subsequent runs.

## Homebrew integration and boundaries

Selecting older eligible releases is a core design requirement. Homebrew
documents historical formula installation through `brew version-install` and
`brew extract`, but maintaining extracted formulae becomes the caller's
responsibility. These are building blocks to evaluate, not proof that arbitrary
historical packages and their dependencies can be installed reliably. See
[Homebrew's versioning documentation](https://docs.brew.sh/Versions).

The installation strategy remains to be proven for formulae, casks, and their
dependencies. The project would not silently fall back to checking only the
latest release when historical installation is unavailable.

The policy would apply only to upgrades performed through `brew-cooldown`.
Manual `brew upgrade` commands, application self-updaters, and updates to
Homebrew itself would remain outside its control. It would not provide
transactional upgrades or automatic rollback.

## Before implementation

The detailed design needs to establish reliable age sources, historical
candidate and artifact availability, compatible dependency selection, and the
evidence required for security exceptions. It also needs to show how Homebrew's
actual installation operations can be constrained to the evaluated versions
without breaking other installed packages. Those decisions belong in design
documents before an executable upgrade path is added.

An implementation must demonstrate progress through frequent package and
dependency releases while preserving every selected candidate's cooldown.
Historical installation is a feasibility gate for that promise, not a feature
to defer until after a latest-only updater ships.

Distribution through Homebrew is a goal for a future release. This project is
independent of Homebrew and does not imply endorsement or acceptance into its
package repositories.
