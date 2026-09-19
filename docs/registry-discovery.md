# Registry discovery

The registry adapter enumerates official core bottle tags during each run and
resolves a requested tag to immutable index, platform manifest and bottle
digests. It does not keep a release catalog. Mutable tag lists and tag lookups
are fetched afresh through Homebrew's curl helper; immutable documents use
Homebrew's resource cache and checksum verification.

Pagination is complete only when the registry returns no next link. A failed
page, unexpected response, repeated link or unexpected origin is an explicit
discovery failure. Callers must report it as incomplete discovery, rather than
an empty or complete version history. Fresh public-registry requests use
Homebrew's anonymous access header, so a private mirror's credentials cannot
escape to the public host. Immutable resource downloads retain Homebrew's
native cache and mirror behavior. Redirects during fresh lookup are reported
instead of forwarding authorization to an unexamined destination.

The JSON parser owns document syntax. Validation binds the exact core name,
index reference and package version, rebuild, platform reference, descriptor
digest, manifest digest and bottle layer digest. The platform's publication
timestamp belongs to that manifest; the index creation date is not substituted
for it. A missing platform timestamp remains absent for the observation-clock
fallback. A malformed timestamp is an error.

The adapter returns metadata, not authorization to install. Verified bottle
provenance, embedded recipe identity, version scheme, native platform checks
and dependency compatibility still belong to candidate preparation. A registry
hash alone cannot set a policy candidate's `verified` field. Tag enumeration
does not infer version schemes or throw away history using a guessed version
grammar. The caller resolves promising tags and evaluates actual recipe data.

The pagination reader accepts the registry's single next-link form, resolving
relative URLs through Ruby's URI parser. It validates the full destination
before any request. Unknown link syntax fails visibly; it cannot silently
truncate history. No source text, shell output or formula Ruby is parsed here.

## Verification

Recorded registry responses exercise pagination, immutable identity and
publication-time selection. Modified copies test wrong origins, loops,
contradictory digests and malformed metadata. The live integration probe
enumerates historical tags and resolves an old platform manifest through the
native cache. It changes no installed packages.

```sh
HOMEBREW_DEVELOPER=1 brew ruby -- test/unit/registry.rb
HOMEBREW_DEVELOPER=1 brew ruby -- test/integration/registry.rb
```
