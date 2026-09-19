# Security evidence

The advisory adapter evaluates an installed package and a candidate against the
same snapshot of Homebrew's advisory feed. It uses Homebrew's JSON loader,
normal cache and version-range evaluator. A successful network refresh stamps
the snapshot with the caller's request-start time; reading a cached file never
establishes freshness. Refresh failures are reported and cached adverse
evidence remains usable. No advisory data is stored in product state.

Package matching includes the formula kind, official tap and exact versioned
name. Formula revisions participate in comparison. A feed without matching
records means unknown coverage, not an assurance of safety. Unsupported or
malformed evidence cannot authorize a security exception; valid adverse
evidence from other records still holds the candidate.

## Evidence boundary

The JSON parser owns whitespace, escaping and document syntax. The adapter
validates the fields that can change an eligibility decision: schema major,
record identity, withdrawal, package identity, version lists, range types and
event shapes. Supported ranges are Homebrew ecosystem versions and semantic
versions. Unknown range kinds remain visible as unknown evidence. Event
boundaries must be ordered and comparable before a negative assessment is
accepted; an ignored or uncomparable range must not become a clean result.

The native range evaluator supplies affected and fixed states. An explicit
`fixed` event is required for expedited adoption; a `limit`, `last_affected`
or absence from a version list is not a fix. The installed-affected and
candidate-fixed results must belong to the same non-withdrawn advisory.
Another advisory affecting the candidate prevents the exception. An unknown
candidate assessment prevents the exception too, while leaving routine
age-qualified upgrades available.

A Homebrew patch annotation needs evidence from the selected verified recipe,
not today's formula API. Its resolved identifiers must name the advisory
directly, one of its aliases, or every directed upstream reference. Those
references are not collapsed into aliases. Without matching recipe evidence,
a patch-based fixed range remains unknown. Recipe evidence does not override a
range that still reports the selected version affected.

## Time and execution

The caller supplies timestamps. The policy checks refresh age, including its
upper bound and future-clock rejection. Execution must refresh and reassess;
an earlier plan carries no lasting authorization. There is no scheduled event,
persisted advisory snapshot or private feed mirror to reconcile. The scheduler
sets the next opportunity to discover a security fix.

## Verification

The recorded fixture contains upstream records retrieved from the source named
inside it. Tests use their real revision boundaries, then modify copies to
exercise withdrawn records, unsupported types, malformed fields and incomplete
fix evidence. These tests run through Homebrew's native range evaluator:

```sh
HOMEBREW_DEVELOPER=1 brew ruby -- test/unit/advisories.rb
```

Live refresh has a separate read-only probe. It refreshes Homebrew's ordinary
advisory cache and evaluates explicit version pairs without changing packages:

```sh
HOMEBREW_DEVELOPER=1 brew ruby -- test/integration/advisories.rb
```

The feed format is documented by the [Homebrew advisory project][homebrew] and
the [OSV schema][osv]. Upgrade workers refresh the feed and reassess selected
candidates before entering the installer.

[homebrew]: https://github.com/Homebrew/advisory-database/blob/main/CONTRIBUTING.md
[osv]: https://ossf.github.io/osv-schema/
