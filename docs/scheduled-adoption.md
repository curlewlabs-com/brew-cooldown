# Scheduled adoption

The checkout performs policy-selected formula and cask upgrades on the validated
runtime. It replaces the upgrade phase for a qualified, installed Brewfile
scope; provisioning remains a separate operation. A partial result remains an
error for the scheduler even when independent upgrades succeed.

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

The native installer adapter is validated against one Homebrew commit, recorded
in `lib/brew_cooldown/validated_homebrew.rb`; the
[boundary experiments](installer-boundaries.md) describe the qualification runs.
The scheduler checks that commit before execution. `upgrade` checks the
runtime before it plans: on any other commit, or on a checkout with
local changes, it reports `unsupported_runtime` without downloading candidates
or starting a component. Each component checks again before its first mutation.
`plan`, `explain` and `recover` install nothing and stay available.

Qualification follows Homebrew's releases. Runtime adoption uses Homebrew's
native update lifecycle only when its latest release is qualified. If the
installed runtime already matches qualification while a newer release is
waiting, defer Homebrew's self-update and keep package upgrades on the approved
runtime. Homebrew's update migrations wait with that self-update. Package
discovery fetches current upstream metadata independently of
`brew update`; use native update when permitted so Homebrew also performs its
prefix migrations.

Do not restore an older runtime with a raw Git checkout after a newer Homebrew
has used the shared prefix. Qualification starts from a fresh prefix at the
target commit; it does not establish backward compatibility with prefix state
that a newer release may have migrated. An ahead or unrelated checkout remains
an error until that runtime is qualified.

Release qualification must run the native installation, dependency, hook and
recovery experiments on each newly supported Homebrew runtime. The Qualify
workflow runs them on every pull request that moves the qualified commit; see
[contributing](../CONTRIBUTING.md#supporting-a-newer-homebrew). Broader runtime
compatibility needs evidence from that qualification; a version range alone
does not establish it. A scheduler that cannot select the approved runtime
must surface that failure rather than bypass validation.

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

## Consumer qualification

Use [the conservative profile](../examples/conservative.json) with an explicit
Brewfile path. It preserves the default adoption windows while making a
scheduler's policy reviewable independently of later default changes:

```sh
/path/to/brew-cooldown/bin/brew-cooldown plan \
  --config /path/to/brew-cooldown/examples/conservative.json \
  --brewfile /path/to/Brewfile --json
```

Before activation, provision the consumer's actual Brewfile in an expendable
Apple Silicon VM using ordinary Homebrew, starting from a fresh prefix at the
qualified commit as the [Qualify workflow](../.github/workflows/qualify.yml)
does. Validate the full workload through
`test/integration/brewfile_acceptance.rb`, with `HOMEBREW_COOLDOWN_DISPOSABLE=1`
and `HOMEBREW_COOLDOWN_TEST_BREWFILE` naming the provisioned file. This
exercises the checkout commands and conservative profile; the consumer's
Brewfile stays outside this repository. It changes no scheduler.

Qualify both an up-to-date installation and an installation with an eligible
historical baseline. For the latter, set
`HOMEBREW_COOLDOWN_TEST_REQUIRE_UPGRADE=1`: the test requires a completed native
installation and changed installed inventory, so a successful no-op cannot
stand in for an upgrade. The [installer experiments](installer-proof.md) and
[cask experiments](cask-execution.md) describe the historical fixtures. Restore
fixtures only in the disposable VM, with no package-changing process running.

`test/integration/command_help.rb` exercises both the direct launcher and
Homebrew's external-command help dispatch. Run it with `brew ruby --` when
qualifying a Homebrew runtime; successful exit alone cannot establish that
Homebrew displayed the updater's help.

## Checkout installation

Use a dedicated checkout whose files stay in place while a job runs:

```sh
git clone https://github.com/curlewlabs-com/brew-cooldown.git /path/to/brew-cooldown
/path/to/brew-cooldown/bin/brew-cooldown --help
```

There is no separate Ruby installation step: the launcher uses Homebrew's
portable Ruby. Invoke the launcher by its checkout path, or add the checkout's
`bin` directory to `PATH`.
The launcher locates its Ruby files relative to itself, so copying or symlinking
the launcher alone into another directory does not install the tool.

Provision the Homebrew `gh` formula and authenticate the account that will run
the job. Homebrew uses GitHub credentials for bottle attestations and source
history; unauthenticated source-history requests have a smaller API allowance.
An existing authenticated GitHub CLI or Homebrew's supported
`HOMEBREW_GITHUB_API_TOKEN` environment variable supplies those credentials.
The updater reports missing prerequisites instead of installing them during
planning. Keep credentials out of configuration files and scheduler logs.

On macOS, verify authentication in the scheduler's execution session. A token
available from the GUI session's Keychain can be unavailable to an SSH shell
with the same account, `HOME` and `PATH`. After activating a LaunchAgent,
trigger its installed job through `launchctl kickstart` in that account's GUI
domain and inspect its logs. An SSH-only `gh auth status` failure does not
establish that the saved token is invalid; confirm access from the job's
session before replacing working credentials.

Keep configuration and the consumer Brewfile under review. Run a plan with the
same absolute paths and account that the scheduler will use. A successful plan
does not authorize later installation: `upgrade` computes a fresh plan and
checks it again before applying each selected operation.

## Scheduler contract

After qualification and activation review, refresh the dedicated updater
checkout to its reviewed default branch. Its
`lib/brew_cooldown/validated_homebrew.rb` export loads through system Ruby
without entering Homebrew. Refuse local changes in Homebrew's checkout and
compare its current commit with qualification before deciding on a native
update:

- If the current runtime matches and the latest release is unqualified, retain
  the current runtime and proceed with package upgrades.
- If the latest release is qualified and the current runtime is its ancestor
  or already matches it, run native `brew update --force` with
  `HOMEBREW_UPDATE_TO_TAG=1`, then recheck the resulting commit.
- Otherwise, report the mismatch without changing the runtime. Never downgrade
  the shared prefix to clear a compatibility error.

The native update can observe a release published after the preflight check.
An identity mismatch afterward remains an error, not a reason to roll back.
After runtime preparation succeeds, invoke the upgrade command:

```sh
set -eu
exec /path/to/brew-cooldown/bin/brew-cooldown upgrade \
  --config /path/to/brew-cooldown/examples/conservative.json \
  --brewfile /path/to/Brewfile
```

An unconditional `brew update` can move Homebrew ahead of qualification,
including after a successful package upgrade. Runtime adoption therefore needs
the qualification check in either position. The launcher disables Homebrew's
automatic update during execution.

Provide `/opt/homebrew/bin` on `PATH` and a stable `HOME` for the installing
account. Preserve stdout, stderr and the command's exit status in scheduler
logs. The command emits structured operation diagnostics on stderr, one JSON
object per line, each with `elapsed_seconds` since the command began; the gaps
between them show where a slow run spent its time, and `phase` and
`prepare_candidate` events mark the steps that log nothing else. `--json`
selects machine-readable results on stdout. Cooldown holds and explicit pins
can produce a successful run with no installations. Missing scope, incomplete
evidence and installation failures produce a nonzero exit even if independent
upgrades complete.

A weekly run can leave a verified security fix waiting until the next week.
More frequent runs make the security bypass useful sooner without shortening
routine release delays. `upgrade --security-only` limits execution to components
containing an evidenced installed-vulnerability fix; their dependencies still
need eligibility. Cask advisory coverage is explicitly unsupported, so this
mode cannot promise expedited cask fixes.

Avoid overlapping package-changing Homebrew commands. After a failed run,
inspect its diagnostics and use `brew-cooldown recover` to inspect any
unfinished operation. Follow [the recovery procedure](execution-recovery.md) to
choose a repair and acknowledge the resulting state. The job must not substitute
a plain `brew upgrade` or `brew bundle install --upgrade` after a cooldown
failure: those commands select versions outside the assessed policy.

Provision newly declared packages explicitly before the next scheduled upgrade.
Keep the scheduler's state directory stable across runs so fallback observation
times survive; leave artifact caching to Homebrew. The launcher preserves
`XDG_STATE_HOME` and `XDG_CONFIG_HOME` when entering Homebrew's filtered
environment. Normal cleanup of Homebrew caches can require downloads again but
does not reset verified publication dates or stored fallback observations.
