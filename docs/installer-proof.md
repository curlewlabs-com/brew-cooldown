# Historical installer experiment

Status: the baseline and historical upgrade experiment passed; the broader
executor feasibility gate remains open. This is a destructive integration
experiment for an expendable Apple Silicon macOS Tahoe VM. It is not a
user-facing command or a supported executor. Do not run it on a workstation
or a shared runner.

## Observed result

On 2026-09-18, the baseline and upgrade commands below passed in a disposable
macOS 26.6.2 VM at the standard Homebrew prefix. The Homebrew commit was
`edb70f031e4170c780799633a1226ff73e1077f4`.

| Formula | Baseline | Selected upgrade | Current API version during test |
| --- | --- | --- | --- |
| pcre2 | 10.46 | 10.47 | 10.48 |
| ripgrep | 15.0.0 | 15.1.0 | 15.2.0 |

The run verified official bottle attestations and digests, installed through
the native dependency installer, and checked receipts, canonical `opt` links,
the `rg` alias and execution of a PCRE expression. Unrelated package receipts
and `opt` links were unchanged. Missing graph entries, unplanned dependencies,
current and HEAD recipe substitutions, source fallback and disabled dependency
checks were refused before package mutation.

This establishes that a historical application and its historical dependency
can be upgraded together through the native installer while newer releases
exist. It does not establish compatibility for arbitrary dependency changes
or the remaining execution cases below.

## Reproduce in a disposable VM

The experiment uses the Homebrew checkout named in the integration test and
the normal `/opt/homebrew` prefix. It requires a Homebrew-installed `gh`,
GitHub credentials for Homebrew's attestation verifier, and network access to
Homebrew's official registry and GitHub. It must start without PCRE2 or
ripgrep installed. The VM can otherwise have its usual packages installed.

`test/integration/candidates.json` pins official OCI indexes for the baseline
and upgrade. These are test inputs, not a retained production history catalog.
The candidate loader downloads through Homebrew's cache, verifies immutable
registry digests, and checks Homebrew attestations before evaluating the
embedded recipe. The installer receives a normal native bottle, never a local
bottle path. Recipe text is not rewritten.

The process-local candidate map rejects unknown dependency lookups and
current-formula substitutions. Source fallback and disabled dependency checks
must fail before mutation. Homebrew's requirement traversal normally loads
build-only dependencies even for bottles. The adapter omits those edges unless
the bottle also names them as runtime dependencies, then lets Homebrew perform
its normal runtime and platform checks. No source build is permitted.
The launcher uses developer mode to enter Homebrew Ruby without changing its
persistent settings. Native installation temporarily uses ordinary runtime
mode: the developer-only source-cycle diagnostic otherwise resolves build
recipes even for bottles. The planner checks installation cycles, and native
runtime dependency, architecture and pin checks remain enabled.

The integration test uses Homebrew's normal installer, including dependency
installation, relocation and receipts. It checks canonical and alias links
against explicit expected paths; Homebrew's `Formula#prefix` can return an
`opt` path after linking and is not an independent expected Cellar path.

Inside the expendable VM, set `HOMEBREW_GITHUB_API_TOKEN` through a secure
environment or use an existing authenticated `gh`. Do not put credentials in
the test input, command history, logs or repository. From this checkout run:

```sh
export HOMEBREW_COOLDOWN_DISPOSABLE=1
export HOMEBREW_NO_AUTO_UPDATE=1
export HOMEBREW_NO_INSTALL_CLEANUP=1
export HOMEBREW_NO_ANALYTICS=1
export HOMEBREW_VERIFY_ATTESTATIONS=1
brew ruby -- test/integration/historical_install.rb baseline
brew ruby -- test/integration/historical_install.rb upgrade
```

The historical packages only process fixed test strings in the disposable
VM. This experiment does not certify those releases free of vulnerabilities.
An absent advisory match is not such evidence. Destroy the VM afterward.

This baseline experiment continues to refuse recipes defining hooks. The
separate [boundary experiments](installer-boundaries.md) exercise a constrained
native hook worker and reproduce a concurrency gap in Homebrew's package
locking. Further boundary experiments cover shared consumers, compatibility
evidence, interruption, inventory drift and interpreter upgrades. The broader
[acceptance checks](verification.md) still apply before unattended execution.
