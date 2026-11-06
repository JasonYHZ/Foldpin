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

## Verified cleanup state — November 6, 2026

- Main and both release tags were rewritten and pushed atomically with explicit leases. A new mirror cloned from GitHub contained only main and the two intended tags. A scan of all 648 reachable file objects and commit/tag metadata found no matches for the tested personal-path, private-email, Apple-team, chat-share, private-key, or common credential formats. This is a bounded scan, not proof that every possible secret format is absent.
- Both package sets were rebuilt from clean source commit `83d150970478d86e1998ebbd2e1a940816f7b0ec`; regular build 2 and Preview 1 build 1 retain their respective application versions. Each passed compiled-language checks, corresponding-source hashes, manifest checksums, strict extracted-app signature checks, and scans of 320 ZIP members. Both DMGs were mounted read-only; 41 files in each matched the ZIP and passed the tested privacy patterns. Both CPU targets remain macOS 26.5.
- All 138 application source/resource files are byte-identical to the prior regular release. The changes affect public documentation, signing configuration, history, and packaging paths.
- The prepared Cask parses with Homebrew 7 and uses the rebuilt regular ZIP SHA-256 `b4e74c92774ca06b61f945d9562b16b945eb53dd10f3ae182fdb4e8d08e9ce68`. Existing remote release attachments have not yet been replaced and must not be used for public distribution.
- GitHub showed no Actions run history and zero open or closed pull requests. However, an old commit URL still resolved after the history rewrite. The current GitHub repository therefore remains private; server-side retention has not been cleared.
- The maintainer has been asked whether to retain the current repository as a renamed private archive and create an independent clean repository under the original name. That route avoids depending on deletion of GitHub's retained objects; no rename or visibility change has been performed yet.
