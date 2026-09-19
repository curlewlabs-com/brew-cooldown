# Command planning

Commands use the configuration and exit-status contract in
[system design](design.md#command-contract). Configuration is strict JSON;
unknown keys and ambiguous package identities are errors. Command-line scope
overrides configured scope. Relative paths are resolved against the directory
that supplied them, so a scheduled invocation does not reinterpret a configured
Brewfile relative to its working directory.

Homebrew's own Brewfile evaluator supplies entries and conditional behavior.
It evaluates trusted Ruby configuration but does not invoke Bundle's installer
or entry installation hooks. Missing roots remain missing. Installed receipts
resolve tap identity before an unqualified name is assumed to be core.

Inventory uses actual active links and installed receipts. Old retained kegs
are available for manual recovery, not alternative active baselines. Conflicting
links and missing receipts become explicit assessment errors with recovery
commands. Formula and cask receipts supply reverse-dependency constraints,
including consumers outside the selected scope. Current API recipes cannot
rewrite those installed requirements.

Brewfile scope includes the installed runtime dependency closure. These
dependencies are upgrade targets even if their requesting root is unchanged or
pinned; each keeps its own pin, cooldown and security assessment. Scope output
identifies the consumers that brought an added package into scope. Traversal
follows installed dependencies, not reverse consumers or build-only recipes.

Cask dependency receipts record packages present at installation. Those edges
require an active package; they do not claim bottle build-time ABI evidence.
Formula consumers continue to constrain the same dependency through their
recorded bottle requirements. Native cask pins are included in both scope
decisions and inventory fingerprints.

Homebrew's installed receipt does not reliably retain the bottle rebuild
identity. An embedded recipe's default rebuild value cannot establish which
bottle was poured: the recipe can have no bottle block, or carry older bottle
metadata. Inventory therefore represents the installed rebuild as unknown.
Rebuild-only candidates receive an explicit identity diagnostic with inspection
and forward-repair commands. An already installed version and revision do not
fail the run solely because its bottle rebuild is unknown. This follows native
Homebrew's version-based upgrade boundary, without claiming identical installed
artifact bytes. A known installed vulnerability without an actionable fix still
fails assessment. Retaining a dependency at its recorded package version
and revision follows Homebrew's installed-dependency contract, which does not
require a bottle rebuild. This does not establish exact installed artifact
identity. Replacing a dependency uses exact build evidence or an explicit
compatibility identifier.

Installed identity relies exclusively on Homebrew's receipts and installed
recipes. The tool does not save a supplemental installation receipt, including
for its own upgrades. Version and revision advances remain available when
eligible; rebuild-only uncertainty is reported without blocking independent
work. The earlier
fixed-artifact installer experiments establish their tested installation and
runtime behavior, not a general way to infer an installed bottle's rebuild.

Candidate preparation checks official provenance before loading embedded Ruby.
The planner receives native build identity, dependency requirements and
candidate-specific age and security decisions. Its graph exists only for the
invocation; cache data stays with Homebrew. Human and JSON output are views of
the same result. Homebrew diagnostics go to stderr so JSON remains parseable.
Preparing a candidate can download its bottle to verify provenance and read
the embedded recipe. Formula withdrawals are checked against fresh current
metadata before historical recipes are evaluated.

`upgrade` first confirms that Homebrew is the
[validated runtime](scheduled-adoption.md#homebrew-runtime-changes), then
computes a fresh plan, revalidates selected artifact and security evidence, and
executes independently resolved formula and cask components.
`--security-only` selects components containing an evidenced
installed-vulnerability fix; dependencies still need normal eligibility. Casks
use the native adapter described in [cask execution](cask-execution.md).
Third-party taps remain explicit unsupported scope. The result includes
proposed selections and actual execution outcomes separately.

Run the current read-only command from a checkout:

```sh
./bin/brew-cooldown plan --brewfile /path/to/Brewfile --json
```

Apply eligible upgrades with `./bin/brew-cooldown upgrade --brewfile
/path/to/Brewfile`. Inspect unfinished work with `./bin/brew-cooldown recover`.
These commands do not run Brewfile installation hooks or install missing roots.

`explain PACKAGE` runs the same scope assessment and focuses its human output on
the requested package's installed version, candidate decisions, eligibility
times, security coverage and dependency component. It accepts the same explicit
scope options as `plan`, or uses configured scope. It does not add the named
package to scope. The query matches declared roots and their installed runtime
dependencies. An outside-scope name is reported without widening the plan;
an ambiguous name requires a canonical `formula:TAP/NAME` or `cask:TAP/NAME`.
Qualified tap names and declared Brewfile aliases also identify scoped packages.

Explanations retain assessment errors from the whole scope, since a focused
view must not turn a failed plan into success. JSON includes the full plan plus
an `explanation` object with the matched identity and native installed baseline.
No separate explanation cache or saved plan is maintained.

Discovery first reads fresh current formula metadata to establish Homebrew's
version scheme. When that matches the installed scheme, native version
ordering excludes old tags before downloading their bottles. A scheme change
requires inspecting old-looking versions too. Registry references disambiguate
upstream version suffixes from bottle rebuild suffixes. Every selected candidate
still gets its actual version scheme from the verified embedded recipe.
An actively disabled formula is reported with Homebrew's reason; loading an
older recipe cannot bypass that current withdrawal signal.
Candidates ahead of Homebrew's currently published version, revision or rebuild
are rejected too: a rollback can leave the withdrawn artifact in the registry.
Version-scheme ordering still takes precedence over ordinary version strings.

Cask discovery uses fresh official metadata to anchor the source history to a
Homebrew commit. Each historical recipe is bound to its Git blob, loaded through
the native cask evaluator and paired with its verified vendor download. The
source commit supplies the age of that exact recipe and checksum; missing or
unusable dates use the observation fallback. Current withdrawals and version
rollbacks constrain historical candidates. Independent recipe identities keep
their own clocks, and equally versioned eligible recipes prefer the later
publication. See [cask execution](cask-execution.md).

## Verification

`test/integration/command_explain.rb` runs the actual package explanation with
an empty Homebrew cache. It compares the reported baseline with the native cask
receipt and checks that the complete scope assessment and security coverage
survive the focused view, without changing installed state. This also exercises
upstream history discovery without fixture downloads or a private catalog.

`test/integration/runtime_scope.rb` passed with Codex pinned at its historical
baseline. Its installed PCRE2 and ripgrep dependencies advanced while the cask
receipt and pin remained unchanged. The retained cask and upgraded dependency
binaries ran, and the repeated plan succeeded while still reporting unknown
installed bottle rebuild identity. The test uses the historical formula and
cask baseline fixtures described in the installer experiments.

`test/integration/command_cask_plan.rb` passed against a historical Codex
installation in the disposable Apple Silicon VM. The command selected
`0.153.4` while the current `0.155.1` was still cooling, reported unsupported
cask advisory coverage, and left installed state unchanged. A native cask pin
prevented the same upgrade. Recorded source fixtures exercise history
pagination, blob verification and missing publication evidence separately.

`test/integration/command_plan.rb` runs the actual command against retained
historical installations in an expendable VM. It checks that advancing
candidates are selected, a native pin prevents selection, JSON stays parseable,
and planning leaves package receipts and links unchanged. Its setup restores
the active kegs and pin state afterward. The unit tests cover configuration,
withdrawals, dependency identity, and terminal recovery instructions alongside
the policy, planner, registry, and advisory tests.

`test/integration/command_upgrade.rb` runs the actual upgrade command against
historical fixtures in the disposable VM, verifies native receipts and runtime
linkage, and checks that successful journals are removed. Its `partial` mode
holds the first component's native Ruby lock while PCRE2 and ripgrep upgrade.
Use a minimal fixture prefix for that mode: additional installed consumers can
connect Ruby and PCRE2 through shared runtime dependencies. In that connected
graph, holding either package's lock correctly holds the entire component and
does not exercise independent progress. Full-Brewfile qualification is a separate
check.
`test/integration/command_recovery.rb` checks inspection and acknowledgment of
unfinished work, including rejection when inventory or the journal set changes.
