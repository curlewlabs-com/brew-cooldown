# Scheduled adoption

The checkout can perform policy-selected formula and cask upgrades on the validated
runtime. It is not yet a complete replacement for a job that runs `brew update`
followed by `brew bundle install --upgrade`. A partial result remains an error
for the scheduler even when independent upgrades succeed.

## Casks and shared formula dependencies

A Brewfile containing casks needs the cask adapter. Core-formula bottle
verification cannot establish the identity and age of a cask's vendor payload.
Cask planning now uses historical recipe provenance, immutable download
identity and source publication evidence. Command execution uses native
installation and the shared operation journal while preserving the selected
dependency plan.

Casks already constrain the installed graph. A cask depending on a formula can
therefore affect that formula's component even when the cask itself is outside
the requested upgrade scope. Cask receipts supply runtime package
requirements rather than bottle ABI constraints. Native installation and
retained-dependency behavior have passed the disposable-VM experiment.

Qualification must include the actual Brewfile and its runtime closure before
changing scheduling. Keep unsupported candidates visible and continue
independent work. Running
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

Installed runtime dependencies are upgrade targets alongside Brewfile entries,
even when the entries stay unchanged. Scope follows Homebrew's installed
receipts, and each added target identifies its requesting consumer. Packages
outside that closure remain fixed compatibility constraints. New dependencies
required by a selected candidate still receive their own policy assessment.
