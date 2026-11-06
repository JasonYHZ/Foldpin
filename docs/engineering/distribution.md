# Universal macOS distribution

Foldpin uses GPL-3.0-only source distribution and universal GitHub Release packages. The first regular release is 0.1.0, application build 2; historical Preview 1 uses build 1. The maintainer recreated the GitHub repository as public after cleanup. Only the clean main branch and regular release tag are uploaded to the new repository; the Preview 1 release is not recreated. Homebrew uses the project-maintained tap.

## Build

From a clean source commit, run:

```sh
python3 scripts/package-release.py --version 0.1.0 --build 2 --label 0.1.0
```

Requirements: Xcode, Python 3, and macOS tools ditto, codesign, and hdiutil. The script freezes application source, tests, scripts, licenses, and selected documentation. It builds outside the checkout, maps compiler source paths, and uses an ad-hoc signature with no development team or debug entitlement. It does not launch the app, commit, tag, or upload.

The ignored output directory `dist/Foldpin-0.1.0/` contains five public files:

- `Foldpin-0.1.0-universal.dmg`: recommended installer, arm64 and x86_64.
- `Foldpin-0.1.0-universal.zip`: the same application and notices.
- `Foldpin-0.1.0-source.zip`: the matching source snapshot and licenses.
- `build-info.json`: source commit, source hashes, toolchain, architectures, and normalized build arguments.
- `SHA256SUMS`: hashes of the four preceding files.

`build.log` is local diagnostic output and must not be uploaded. It may contain local paths. The script refuses to overwrite an existing output directory; preserve old packages privately when rebuilding.

## Verify and publish

Verify universal architectures, both deployment targets, strict signature integrity, sandbox entitlements, absence of debug permissions, version/build, all eight compiled languages, matching source hashes, ZIP extraction, DMG integrity, checksums, and absence of personal paths or private identifiers in package members. A tag must point to the clean source commit recorded in its build-info.json. Publish the matching source archive alongside the binaries.

The new repository does not inherit old release assets. Recreate the regular release with all five cleaned files; the earlier executables embedded personal build paths. Keep the old packages only in the private local backup. Compare GitHub's SHA-256 for every attachment before recommending installation. See the [cleanup record](public-repository-preparation.md).

## Signing and validation limits

The application is not Developer ID signed or notarized. Users may need the system's Privacy & Security approval after verifying the source; do not disable Gatekeeper or remove system protections. The minimum system is macOS 26.5, including for Intel Macs.

Universal compilation does not establish Intel hardware, minimum-OS hardware, fresh-user, real Gatekeeper, upgrade, live-media, or full accessibility validation. See [release assessment](release-0.1.0.md).

## Homebrew

The prepared [Cask](../../Casks/foldpin.rb) uses the regular universal ZIP. Update its checksum after rebuilding. Verify anonymous downloads and installation after the new release attachments have been uploaded. See [Homebrew preparation](homebrew.md).
