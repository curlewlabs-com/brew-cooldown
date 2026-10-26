# Installed-state inspection and package authority

The installer uses formula objects both to select packages and to ask about
existing installations. These have different authority. `ExactMap` resolves
only the verified candidates and retained dependencies in a component. It never
falls back to today's API or a tap recipe. `InstalledState` answers native
bookkeeping queries from the prefix and recipes already in installed kegs;
its answers cannot authorize installation.

This distinction matters before unlinking. Homebrew's Info documentation
maintenance asks whether texinfo supplies `install-info`, even when texinfo is
absent. Loading a formula for that check used to fail the exact resolver partway
through unlinking Coreutils. Helper discovery now resolves an existing
executable, and sibling traversal loads installed recipes directly instead of
temporarily widening the candidate resolver. Absent siblings are absent, not
requests to load a current recipe.

## Native boundary audit

The qualified Homebrew source is the authority for the calls described here.
Qualification must repeat when that runtime changes.

| Native use | Answer or enforcement |
| --- | --- |
| Candidate and runtime dependency resolution | Exact candidate map, including bottle build metadata and retained dependency compatibility |
| Conflict checks | Existing linked-keg and opt records; no recipe load |
| Sibling traversal for linking | Installed keg recipes; no current recipe and no candidate-map expansion |
| Info documentation helper | System executable, then the active installed helper's opt path; no installation |
| Source-cycle and build-only dependency diagnostics | Disabled developer diagnostic during bottle installation; runtime checks retained |
| Candidate prelude, install, pour and build | Exact formula object and artifact checks; source builds require the trusted release-archive adapter |
| Implicit dependency installation | Refused during a journaled package operation; dependencies must finish their own operations first |
| Unlink, link, optlink and uninstall | Current package only during execution; otherwise an installable candidate in the exact map |
| Link collision overwrite | Existing files belonging to another package are not authorized by a bookkeeping lookup |
| Alias and old-name links | Native handling, with changes checked against the replaced rack |
| Migration and dependent repair | Not entered through the command-level upgrade path; an extra installer or unrelated keg mutation remains refused |
| Post-install and release-archive build subprocesses | Separate exact recipe resolver and native sandbox; nested installers and recursive brew are refused |

Preflight resolves the documentation helper and inspects siblings that native
linking would unlink before the old keg is changed. It refuses displacing a
different linked package. These checks are repeated for each operation, under
the existing native package locks. They are not a simulation of every possible
installer effect: filesystem errors, hook failures and interruption can still
leave partial changes. The journal and explicit
[recovery procedure](execution-recovery.md) remain necessary.

## Evidence

The optional-helper qualification track installs and upgrades historical
Coreutils bottles with texinfo absent and present. It checks command links and
runtime behavior, confirms that inspection leaves texinfo outside the exact
map, and attempts installation and keg mutation outside the authorized set.
The sibling, conflict and hook tracks exercise the other inspection boundaries
and subprocess refusals. See [verification](verification.md) for the release
bar; a successful lookup alone is not installation evidence.
