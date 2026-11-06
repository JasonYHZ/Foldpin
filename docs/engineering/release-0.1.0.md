# Foldpin 0.1.0 release assessment

Version 0.1.0 is the first regular release, with application build number 2. It uses the same application functionality as Preview 1, with English-first repository documentation and an explicit Chinese README. Release labels, package names, application metadata, and source archives must agree.

## Evidence and decision

The existing 310 tests across 10 suites passed in a fresh serial run on November 6, 2026 (8.321 seconds). The suite exercises storage, undo, note lifecycle, import/export, native editor behavior, links, language settings, and MCP-related behavior. No application code changed in this release preparation.

The earlier universal build, package extraction, signature integrity, eight-language compiled-resource checks, and matching-source checks passed. The 0.1.0 artifacts must be rebuilt from the committed release source and rechecked before upload; changing only the GitHub title or checkbox is insufficient.

The regular 0.1.0 artifacts have now been rebuilt from clean commit `816591915ada0f6e183815247ec51ac4177f2bc9`, tagged `v0.1.0`. Validation passed for both architectures and their 26.5 deployment targets, the extracted ZIP's strict signature, application version 0.1.0/build 2, expected entitlements with no debug permission, bundled GPL text, 5,920 compiled translations, corresponding source hashes, DMG integrity, and every SHA256SUMS entry. The source ZIP includes both README languages. No application was launched or real library accessed.

The universal ZIP SHA-256 is `b52042e5eaba404b47c64168d1a98da52912f4a6097155e6dc522729bd96c831`. The prepared Cask parses with Homebrew 7 and matches the regular release URL, version, and local ZIP checksum; installation and an official Homebrew audit have not been performed.

The available automated checks have not identified a blocking functional defect. The maintainer requested a regular 0.1.0 release after review. A regular release is appropriate for this initial feature scope while documenting the limitations below; it is not a claim that all environments have been tested or that the full PRD is implemented.

## Known limitations

- Ad-hoc signature only, without Developer ID signing or Apple notarization. Gatekeeper may block a downloaded copy. A regular GitHub release does not change macOS security behavior.
- Intel hardware and macOS 26.5 hardware have not completed runtime validation. Both CPU architectures compile with a 26.5 deployment target.
- Fresh-user installs, real downloaded-app Gatekeeper behavior, upgrade flows, live recording/playback devices, and complete VoiceOver coverage remain outside the completed checks.
- The repository remains private pending a separate review of historical material. Publishing a release does not authorize changing visibility or rewriting history.
- No official Homebrew submission is being made. Any public tap and eventual official submission follow the open-source launch and the relevant Homebrew requirements.

Back up the entire note library before upgrading. Exporting notes is not a complete library backup.

## Release procedure

1. Commit the documentation, packaging changes, and application version/build metadata on main.
2. Build with `python3 scripts/package-release.py --version 0.1.0 --build 2 --label 0.1.0` from that clean commit.
3. Verify universal architectures, per-architecture deployment targets, signature integrity, expected sandbox entitlements, absence of debug permissions, compiled translations, source-file hashes, ZIP extraction, DMG integrity, and SHA256SUMS.
4. Tag the build commit as `v0.1.0` and publish the five artifacts with the [English release notes](../releases/0.1.0.md), without the Pre-release label.
5. Keep the earlier preview tag and binaries as historical records. Update its description to English and link to the regular release.
6. Update the project Cask's version and checksum to the published universal ZIP after validation. Do not advertise public installation while the repository is private.
