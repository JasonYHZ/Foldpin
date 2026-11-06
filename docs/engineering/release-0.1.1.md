# Foldpin 0.1.1 release assessment

Version 0.1.1 / build 3 is the shortcut-scope layout fix following the published 0.1.0 / build 2. The locally prepared 0.1.0 / build 3 packages are superseded and must not be uploaded. Preserve the published v0.1.0 tag and assets.

The Debug build and isolated native scope regression passed. The regression covers English/Chinese, light/dark appearance, 900×680 and 780×560 windows, visible control placement below the toolbar, native hit testing, and both scope directions. It does not register global hotkeys, start the real app, or access real notes. Broader settings-title issues and validation limits are recorded in settings-reorganization.md.

Build from a clean commit with `python3 scripts/package-release.py --version 0.1.1 --build 3 --label 0.1.1`. Verify architectures, both macOS 26.5 targets, strict signing and entitlements, compiled translations, matching source hashes, ZIP/DMG integrity, checksum manifest, and tested privacy patterns before upload. The tag must point to the source commit in build-info.json.

The maintainer will manually upload the five public files. Keep the new release as a regular-release draft until the files are uploaded and verified. Update the live Cask only when the public 0.1.1 download is available, so existing installations remain usable meanwhile.

Ad-hoc signing is not Apple notarization. Intel hardware, minimum OS, fresh-user launch, actual Gatekeeper launch, upgrades, live media, and full accessibility remain unverified.

## Prepared artifacts and draft

The universal packages were built from clean commit `b309eea8db38eb4238028036ff0c9c6a9b77e2ae`, which is the pushed v0.1.1 tag target. Both CPU deployment targets are macOS 26.5. Strict extracted-app signing, all 5,920 compiled translations, 225 corresponding-source hashes, ZIP/DMG integrity, manifest checksums, and tested personal-path scans passed without launching the app.

The English GitHub Release draft was saved with tag v0.1.1, title Foldpin 0.1.1, and Latest selected (not Pre-release). The maintainer will upload the five public files from the local 0.1.1 output; build.log is excluded. At draft creation, the release had not been published and the live Cask still pointed to 0.1.0.

The new universal ZIP SHA-256 is `8e48074e5741c9ad357759538425004624c91541251ae0c2cf15a49ca110b2dc`.

## Published download and Homebrew update

The public v0.1.1 checksum manifest is now downloadable and byte-identical to the validated local manifest. The public universal ZIP was downloaded anonymously and its SHA-256 matches `8e48074e5741c9ad357759538425004624c91541251ae0c2cf15a49ca110b2dc`. The project Cask is updated to version 0.1.1 with this digest and parses successfully with Homebrew. Existing users can run `brew update` followed by `brew upgrade --cask jasonyhz/foldpin/foldpin`. No installed application was upgraded or launched during this check.
