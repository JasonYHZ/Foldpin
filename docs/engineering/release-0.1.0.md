# Foldpin 0.1.0 release assessment

Version 0.1.0 is the first regular release, application build 2. Preview 1 uses build 1. Both contain the same application functionality. Repository documentation is English-first with a separate Chinese README.

## Validation

310 automated tests across 10 suites passed in serial execution on November 6, 2026. Checks cover storage, undo, note lifecycle, import/export, native editor behavior, language settings, and MCP behavior.

The packages are being rebuilt following the maintainer-authorized repository privacy cleanup. The build now uses a temporary source directory outside the checkout, maps compiler source paths, clears the development team, and rejects executables containing personal home-directory paths. All five assets for each release must be replaced together, including the matching source, build metadata, and checksum manifest. The tag must identify the clean source commit recorded in build-info.json.

Required checks: arm64 and x86_64, per-architecture macOS 26.5 deployment targets, strict signature integrity, expected sandbox entitlements without debug permissions, application version/build, bundled GPL text, all eight compiled translations, corresponding-source file hashes, DMG integrity, ZIP extraction, package checksums, and privacy scanning of archive members. No real library or application instance is used for these checks.

## Known limitations

- Ad-hoc signature only, without Developer ID signing or Apple notarization. Gatekeeper may block a downloaded app.
- Intel hardware, minimum-OS hardware, fresh-user installs, real downloaded-app Gatekeeper behavior, upgrade flows, live recording/playback, and full VoiceOver coverage remain unverified.
- A regular GitHub release does not establish complete implementation or validation on every system.
- The maintainer recreated the repository as public after cleanup. The regular release is being recreated with the same validated packages; no official Homebrew submission has been made.

Back up the entire note library before upgrading. Exporting notes is not a complete library backup.

## Rebuilt packages

See each release's build-info.json for the exact clean source commit and per-file source hashes, and SHA256SUMS for current package digests. The original private packages and history are retained only in a separate local backup. Existing downloads must not be used as the cleaned public packages.

The regular privacy rebuild completed from clean source commit `83d150970478d86e1998ebbd2e1a940816f7b0ec`. Both architectures target macOS 26.5; strict extracted-app signing, 5,920 compiled translations, 225 corresponding-source file hashes, all manifest checksums, and scans of every ZIP member passed. The maintainer replaced all five regular-release assets; GitHub digests match the cleaned local files, the release is marked Latest, and the prior Preview 1 release has been deleted.
