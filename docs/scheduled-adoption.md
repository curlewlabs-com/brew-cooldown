# Scheduled adoption

The checkout can perform policy-selected core-formula upgrades on the validated
runtime. It is not yet a complete replacement for a job that runs `brew update`
followed by `brew bundle install --upgrade`. A partial result remains an error
for the scheduler even when independent formula upgrades succeed.

## Casks and shared formula dependencies

A Brewfile containing casks needs an additional adapter. Core-formula bottle
verification cannot establish the identity and age of a cask's vendor payload.
That adapter needs historical recipe provenance, immutable download identity,
publication evidence, and execution through the native cask installer while
preserving the selected dependency plan. Availability of an old download alone
does not establish its eligibility.

Casks already constrain the installed graph. A cask depending on a formula can
therefore affect that formula's component even when the cask itself is outside
the requested upgrade scope. The current executor reports that it cannot
validate such an installed consumer. Before enabling those changes, the adapter
must establish what the cask's receipt proves about dependency compatibility
and validate native installation and runtime behavior in a disposable VM.

The next implementation target is a cask with a formula dependency. Prove its
historical upgrade and retained-consumer behavior before generalizing discovery.
Keep unsupported candidates visible and continue independent core work. Running
an ordinary latest-release cask upgrade as a fallback would bypass the user's
cooldown policy.

## Homebrew runtime changes

The native installer adapter is validated against the checkout recorded in
[installer boundaries](installer-boundaries.md). A scheduled `brew update` can
replace that code before execution. The current runtime check reports an
unvalidated checkout before package mutation.

Release qualification must run the native installation, dependency, hook and
recovery experiments on each newly supported Homebrew runtime. Broader runtime
compatibility needs evidence from that qualification; a version range alone
does not establish it. The scheduler should surface compatibility errors until
the installed runtime has passed adapter validation.

## Provisioning and scope

The upgrade command operates on installed roots. Missing Brewfile entries are
reported for provisioning, and Brewfile installation hooks are not executed.
An adoption change must keep provisioning explicit rather than silently turning
new tool installation into a routine cooldown upgrade.

Runtime dependencies are considered when needed for selected root upgrades;
compatible installed dependencies are preferred. Proactively refreshing every
dependency in an installed closure is a different scope policy. Establish that
policy before substituting this command for a job that promises that behavior.
