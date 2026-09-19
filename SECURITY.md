# Security Policy

`brew-cooldown` chooses which package versions a machine installs and then
installs them through Homebrew. "Can it be made to install something the policy
did not select" is therefore its security surface, not a footnote to it.

The design answers that at each boundary. Candidates come only from Homebrew's
official sources: the core bottle registry, the formula and cask API, and the
`Homebrew/homebrew-cask` history. A bottle's registry documents are bound by
immutable digest and its Homebrew attestation is verified before the embedded
recipe is evaluated. A historical cask recipe is bound to its Git blob and its
download to the recipe's checksum. During installation, Homebrew's formula and
cask resolution is bound to the selected candidates, so a substituted recipe, a
source build, a forced bottle or an implicit dependency installation is refused
before it changes a package. A cooldown is bypassed only when advisory evidence
refreshed during the same run proves that the installed version is affected and
that the exact candidate fixes it.
[Homebrew integration](docs/homebrew-integration.md),
[installer boundaries](docs/installer-boundaries.md) and
[security evidence](docs/security-evidence.md) hold the full reasoning.

## Trust boundary

Homebrew, its official publishers and GitHub are inside the trust boundary. The
tool does not defend against a compromised Homebrew installation, and a delay
does not certify a release as safe. A Brewfile is trusted Ruby that Homebrew's
own reader evaluates, and official recipes are trusted Ruby as well. The
post-install worker constrains official hooks; it is not a sandbox for hostile
recipes. Third-party taps are reported as unsupported instead of being
installed.

## Supported versions

This is a pre-release project without tagged releases. Fixes land on `main`.

## Reporting a vulnerability

Report security issues **privately** - do not open a public issue. Use GitHub's
private vulnerability reporting: open the repository's **Security** tab and
choose **"Report a vulnerability"**, which opens a private advisory visible only
to the maintainers.

Helpful details to include:

- macOS version (`sw_vers -productVersion`) and Apple silicon or Intel
- `brew --version` and `git -C "$(brew --repository)" rev-parse HEAD`
- The exact command, its configuration, and a minimal Brewfile
- The JSON diagnostics from stderr, with credentials removed
- What you observed versus expected

This is a small project, so responses are best-effort rather than on a fixed
SLA; we will acknowledge and work toward a fix as soon as we reasonably can.

## Scope

In scope: any path by which a version, recipe, artifact or dependency outside
the evaluated plan could be installed; a cooldown bypass without the required
advisory evidence; an override of an explicit Homebrew pin; credentials reaching
a host other than the one they belong to, or appearing in output; and recovery
output that would lead an operator to run a harmful command.

Out of scope: vulnerabilities in the packages being installed, which belong to
their maintainers; defects in Homebrew itself, which belong upstream; and
interference from package-changing Homebrew commands run at the same time, a
limitation the [boundary experiments](docs/installer-boundaries.md) document.
