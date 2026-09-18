# Verification and implementation order

Status: acceptance criteria. The [installer experiment](installer-proof.md)
records execution results and remaining gaps. Read [system design](design.md)
for the behavior being checked and
[Homebrew integration](homebrew-integration.md) for the integration contract.
The [boundary experiments](installer-boundaries.md) record the native hook
result and the concurrency failure currently blocking unattended execution.

## Prove the installation boundary first

Before implementing general history discovery or planning, exercise the
adapter in a disposable macOS environment at a standard Homebrew prefix.
An alternate prefix can change bottle compatibility and is not a substitute
for this check. Never use a developer workstation as the destructive test bed.

Demonstrate an upgrade to a historical official bottle while a newer release
exists. Its required dependency must also have a newer release available.
Keep canonical formula identities and verify actual receipts, `opt` links,
checksums, and runtime behavior. Use safe historical versions for execution;
old metadata examples in the design are not approved installation targets.

Exercise a formula with an ordinary post-install hook and a shared library
with another installed consumer. Confirm that dependency lookups remain bound
to the plan, supported hooks work, and reverse consumers keep working. Show
both a compatible shared dependency change and a refused incompatible one.

Try to make the adapter substitute a current formula, fetch an unplanned
dependency, rebuild from source, or upgrade an out-of-scope dependent. Every
attempt must stop before that package operation, not merely show a discrepancy
afterward. Verify normal bottle provenance checks still run for staged files.

Change Homebrew's compatibility identity, alter inventory between planning
and apply, contend on package locks, and terminate installation at a package
boundary. Verify refusal, reconciliation, and truthful partial results. Confirm
that upgrading a formula-managed interpreter does not terminate the tool's
Homebrew Ruby runtime.

If this fails, revise the adapter design before broad product implementation.
Do not ship a latest-only updater or an installer that silently skips safety
checks as an interim approximation.

## Deterministic policy and planning tests

Use real domain records and injected fixed UTC timestamps. Include local dates
that differ from UTC and daylight-saving boundaries; policy results must be
unchanged. Check exact eligibility equality and a time just before it.

Expose daily root and dependency releases through recorded upstream history.
Assert that an older compatible candidate is selected when its own wait ends,
that it stays eligible after newer publications, and that each applied artifact
has satisfied its delay or a specifically evidenced security exception.

Include major transitions, pre-1.0 and non-semantic versions, revision-only
changes, bottle rebuilds, changed bytes under an unchanged version, aliases,
same names in different taps, and formula/cask identity collisions. Verify
there are no downgrades and no cooldown reset from discovery pagination.

Exercise observation-based waiting across restarts, cache eviction, and loss
of disposable downloads. Missing identity evidence must block; missing dates
with verified bytes must eventually mature. Clock regression must not make a
candidate prematurely eligible.

Remove a selected artifact from the recorded upstream responses while leaving
another eligible candidate available. Verify reselection without a cooldown
bypass. Distinguish a transient failed fetch from a confirmed missing artifact.
Run again with ordinary Homebrew caches cleared and verify that history is
queried upstream rather than depending on a private catalog. Only the compact
observation ledger and an unfinished journal may be required durable state,
along with the clock-regression timestamp.

Use small real dependency graphs covering shared libraries, incompatible
reverse consumers, independent components, a conflict that requires
backtracking, and competing roots with different wait times. Exhaust the
search budget and distinguish that from proven incompatibility. Demonstrate
that unchanged installed consumers remain constraints even outside scope.

For security, evaluate installed and candidate versions together against
recorded Homebrew advisory payloads. Cover revision fixes, a still-vulnerable
candidate, withdrawn records, range limits without explicit fixes, patch
provenance, stale refresh failure, incomplete coverage, and a young dependency
without its own exception. A successful scan with no matching records is never
an assertion of safety.

## Build in dependency order

After the adapter proof, implement the domain records and deterministic policy,
then scoped upstream history queries and fallback observation clocks. Add
dependency planning and human/JSON explanations before unattended execution.
Connect the proven executor with staging, journaling, and reconciliation last.

Ship tests with each behavior. Use real Homebrew integration for installation
claims; do not reproduce its installer in mocks. Keep live network checks
separate from deterministic recorded-metadata tests. Release validation runs
on the exact Homebrew versions and platform combinations advertised as
supported. New Homebrew releases require that validation before execution is
enabled for them.

Casks and third-party taps are subsequent adapters with the same acceptance
bar. Unsupported scope remains visible until they pass. Publishing, Homebrew
distribution, and any claim of unattended production readiness follow working
evidence; none is implied by these design documents.
