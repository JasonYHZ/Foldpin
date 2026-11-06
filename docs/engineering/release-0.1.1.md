# Foldpin 0.1.1 release assessment

Version 0.1.1 / build 3 is the shortcut-scope layout fix following the published 0.1.0 / build 2. The locally prepared 0.1.0 / build 3 packages are superseded and must not be uploaded. Preserve the published v0.1.0 tag and assets.

The Debug build and isolated native scope regression passed. The regression covers English/Chinese, light/dark appearance, 900×680 and 780×560 windows, visible control placement below the toolbar, native hit testing, and both scope directions. It does not register global hotkeys, start the real app, or access real notes. Broader settings-title issues and validation limits are recorded in settings-reorganization.md.

Build from a clean commit with `python3 scripts/package-release.py --version 0.1.1 --build 3 --label 0.1.1`. Verify architectures, both macOS 26.5 targets, strict signing and entitlements, compiled translations, matching source hashes, ZIP/DMG integrity, checksum manifest, and tested privacy patterns before upload. The tag must point to the source commit in build-info.json.

The maintainer will manually upload the five public files. Keep the new release as a regular-release draft until the files are uploaded and verified. Update the live Cask only when the public 0.1.1 download is available, so existing installations remain usable meanwhile.

Ad-hoc signing is not Apple notarization. Intel hardware, minimum OS, fresh-user launch, actual Gatekeeper launch, upgrades, live media, and full accessibility remain unverified.
