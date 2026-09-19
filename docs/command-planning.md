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

Homebrew's installed receipt does not reliably retain the bottle rebuild
identity. An embedded recipe's default rebuild value cannot establish which
bottle was poured: the recipe can have no bottle block, or carry older bottle
metadata. Inventory therefore represents the installed rebuild as unknown.
Rebuild-only candidates receive an explicit identity error with inspection and
forward-repair commands. Unknown rebuilds cannot satisfy an exact dependency
build match; recorded compatibility identifiers remain usable evidence.

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

This command integration is under development. The separately verified
installer still requires connection to execution-time revalidation, component
dispatch and the command's interrupted-run recovery flow before `upgrade`
is available.

Run the current read-only command from a checkout:

```sh
./bin/brew-cooldown plan --brewfile /path/to/Brewfile --json
```

Discovery first reads fresh current formula metadata to establish Homebrew's
version scheme. When that matches the installed scheme, native version
ordering excludes old tags before downloading their bottles. A scheme change
requires inspecting old-looking versions too. Registry references disambiguate
upstream version suffixes from bottle rebuild suffixes. Every selected candidate
still gets its actual version scheme from the verified embedded recipe.
An actively disabled formula is reported with Homebrew's reason; loading an
older recipe cannot bypass that current withdrawal signal.

## Verification

`test/integration/command_plan.rb` runs the actual command against retained
historical installations in an expendable VM. It checks that advancing
candidates are selected, a native pin prevents selection, JSON stays parseable,
and planning leaves package receipts and links unchanged. Its setup restores
the active kegs and pin state afterward. The unit tests cover configuration,
withdrawals, dependency identity, and terminal recovery instructions alongside
the policy, planner, registry, and advisory tests.
