# Policy core

The policy module evaluates a candidate against an installed baseline, explicit
UTC time and already assessed security evidence. Its Homebrew adapter supplies
version ordering. It performs no installation, network request or clock read.
The defaults and public behavior are defined in [system design](design.md).

Publication evidence belongs to the exact artifact identity. New candidates do
not rewrite existing boundaries. When publication evidence is absent, the
observation ledger preserves the first verified sighting under that digest.
Replacing bytes under a version tag starts a different clock. Losing the
ledger restarts the conservative wait; it cannot make a release look older.
The ledger stores no formula data, dependency graph or artifact archive.

The advisory adapter must provide explicit installed-affected and
candidate-fixed evidence from a non-withdrawn supported advisory. The policy
requires a fresh validation before bypassing age, retains adverse evidence
when stale and honors pins. Upgrade workers refresh the advisory snapshot and
reassess the selected candidates before entering the installer.

## Dependency planning

The planner receives eligible candidates and retained installed options from
discovery. Fixed consumers outside the selected root scope remain constraints.
It resolves independent connected components separately, prioritizes security
fixes and the oldest waiting roots. Installed runtime dependencies in the
Brewfile closure are roots too. Compatible installed dependencies outside that
upgrade scope are preferred over replacements. Native Homebrew version ordering
and recorded compatibility cohorts supply the adapter's comparison and
compatibility rules.

Candidate selection backtracks when the newest eligible version has no usable
dependency closure. A missing dependency from a rejected candidate does not
become mandatory for another candidate that never required it. Rejected root
options retain their conflict explanations. Circular installation dependencies
are rejected before execution, while search exhaustion is distinguished from
proven incompatibility and exposes no partial assignment for execution.

## Time boundaries

Every evaluation receives its timestamp. A cooldown qualifies at equality;
local dates and daylight-saving transitions do not participate. A missing
origin starts observation-based waiting, a future origin is an error, and a
clock earlier than durable state cannot advance it. Security evidence has its
own freshness window, checked independently of candidate age.

The scheduler determines when an eligible candidate is next considered; the
policy promises no exact wakeup. Execution must reassess policy and refresh
security evidence before mutation. There is no saved-plan execution authority,
timer queue or background expiry mechanism to reconcile.

## Verification

These tests use fixed timestamps and Homebrew's actual version comparator.
They do not install packages or access the network:

```sh
HOMEBREW_DEVELOPER=1 brew ruby -- test/unit/policy.rb
HOMEBREW_DEVELOPER=1 brew ruby -- test/unit/observations.rb
HOMEBREW_DEVELOPER=1 brew ruby -- test/unit/planner.rb
```

The environment setting keeps the developer command from changing Homebrew's
persistent developer-mode setting. These dependency graphs exercise the owned
domain model. Live discovery, advisory normalization and execution of resolved
graphs still require integration checks.
