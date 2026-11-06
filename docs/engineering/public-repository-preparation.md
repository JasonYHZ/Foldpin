# Repository privacy cleanup

The maintainer authorized cleanup of repository files and Git history on November 6, 2026. The repository remains private until the cleaned remote history and replacement release assets have been verified.

## Scope

- A complete private repository archive and verified all-refs Git bundle were saved outside this repository before modification. They must never be published.
- Private research, chat summaries and share links, design references, generated design experiments, marketing archives, screenshots, internal handoffs, and the original product-planning archive were removed from main and both release tags throughout their history.
- Personal checkout paths, the personal commit email, Xcode user state, and the configured Apple development team were removed or replaced. Public GitHub project identifiers and required third-party attribution remain.
- Application code, tests, bundled application assets, third-party licenses, and useful technical documentation are retained. Unreviewed reference images are excluded rather than treated as application assets.
- Compiler source paths were found in the earlier application executable. Public packages must be rebuilt with path mapping; changing Git history alone does not clean an existing download.

## Remote completion requirements

1. Scan every blob and commit reachable from main and the two release tags; verify that excluded paths and personal identifiers are absent.
2. Rebuild both package sets from a clean source commit. Verify matching source, signatures, architectures, translations, archive members, and checksums; replace all five assets in each release.
3. Update the Cask checksum and English release descriptions for the rebuilt packages.
4. Push the cleaned branch and tags with explicit leases, verify a fresh remote clone, and check Actions, pull requests, and release assets for retained material.
5. Keep the repository private until the preceding steps are complete. Changing visibility is a separate action.

GitHub may retain unreachable commit objects or cached views after a force-push. This procedure does not certify server-side erasure. If an old private URL still resolves, keep the repository private and investigate GitHub's retention/support process before publication. See [GitHub's removal guidance](https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/removing-sensitive-data-from-a-repository).

## Working with an older clone

Clone the cleaned repository again. Do not merge or force-push an older clone, backup branch, old tag, or private archive into the cleaned repository. Any existing detached development checkout is local archival state and must not be published.
