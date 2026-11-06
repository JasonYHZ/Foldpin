# Foldpin

**Floating sticky notes for Mac. Capture an idea, pin it in view, put it away, and find it again.**

English · [简体中文](README.zh-CN.md)

Foldpin is a native macOS note-taking app built with SwiftUI, AppKit, and NSTextView. Each note lives in its own window, so your tasks, snippets, and reference material can stay beside your work.

## Features

- **Independent notes:** pin, collapse, arrange, and shelve windows; find notes in the shelf and restore recently deleted notes.
- **Native block editing:** headings, lists, tasks, tables, code, images, link cards, and Markdown paste.
- **Local media and files:** record audio, attach audio/video/files, and export notes as Markdown or HTML.
- **Personal appearance:** paper and Liquid Glass surfaces, light/dark themes, note colors, fonts, and custom shortcuts.
- **Eight interface languages:** English, Simplified Chinese, Traditional Chinese, Japanese, Korean, German, French, and Spanish.
- **Optional local MCP server:** disabled by default, with client authorization and access controls. See the [MCP guide (Chinese)](docs/engineering/mcp-support.md).

Notes and attachments are stored locally. Link previews contact the target website. If you enable MCP, authorized external clients can access the content you permit; their subsequent use of that content is controlled by those clients. Cloud sync, built-in AI organization, and speech transcription are not included.

## Download and install

**Requires macOS 26.5 or later.** One universal app supports both **Apple Silicon (arm64) and Intel (x86_64)**. An Intel Mac must also support the required macOS version.

[Download Foldpin 0.1.1](https://github.com/JasonYHZ/Foldpin/releases/tag/v0.1.1)

1. Download `Foldpin-0.1.1-universal.dmg` from the release assets.
2. Open the DMG and drag **Foldpin.app** to **Applications**.
3. Open Foldpin. Back up your complete note library before upgrading an existing installation.

The app is **ad-hoc signed and not notarized by Apple**. macOS may block the first launch. After verifying the download source, check **System Settings → Privacy & Security → Open Anyway**; availability depends on your system policy. Do not disable system-wide security protections.

### Release files

| File | Purpose |
| --- | --- |
| `Foldpin-0.1.1-universal.dmg` | Recommended installer for both chip families |
| `Foldpin-0.1.1-universal.zip` | The same app in ZIP format |
| `Foldpin-0.1.1-source.zip` | Source snapshot used to build this release |
| `SHA256SUMS` | Download checksums |
| `build-info.json` | Source commit, toolchain, and file hashes |

Automated tests, universal compilation, code-signature integrity, and compiled translations are checked. Intel hardware, minimum-OS hardware, fresh-user installs, downloaded-app Gatekeeper behavior, and upgrade flows have not completed manual validation. See [release validation](docs/engineering/release-0.1.1.md).

## Getting started

Create a note with **⌘N**, keep it visible with the pin button, and use the shelf to put notes away and find them later. Type `/` for blocks or press **⌘K** for note actions. Change the interface language in **Settings → General → Language**.

Closing a blank note moves it to Recently Deleted; closing a note with content shelves it. Export is useful for sharing content, but it is not a substitute for backing up the entire library.

## Build from source

Use Xcode with a macOS SDK that supports the deployment target. Open `macOS/Foldpin.xcodeproj`, select **Foldpin / My Mac**, and run. No separate `.xcworkspace` is required.

From the repository root, create a universal release:

```sh
python3 scripts/package-release.py --version 0.1.1 --build 3 --label 0.1.1
```

The script freezes the current source, builds a Release app for both architectures, and generates DMG, ZIP, corresponding source, and checksums under `dist/`. It does not commit, tag, or upload. Build from a clean commit when preparing a published release.

See the [native project guide (Chinese)](macOS/README.md) for development and testing commands, and the [distribution guide (Chinese)](docs/engineering/distribution.md) for packaging details.

## Homebrew

Install from the project-maintained tap:

```sh
brew tap jasonyhz/foldpin https://github.com/JasonYHZ/Foldpin.git
brew install --cask jasonyhz/foldpin/foldpin
```

The explicit Git URL is required because this repository is named `Foldpin`, rather than `homebrew-foldpin`. The fully qualified install command trusts only this Cask in current Homebrew. Review the Cask before installing. The app remains ad-hoc signed and not notarized; the first launch may require approval in macOS Privacy & Security.

Foldpin is **not listed in the official Homebrew Cask repository**. See [Homebrew distribution (Chinese)](docs/engineering/homebrew.md).

## Contributing and license

Report bugs in [GitHub Issues](https://github.com/JasonYHZ/Foldpin/issues) with your macOS version, chip type, Foldpin version, and reproduction steps. Remove private notes, credentials, and personal paths from examples. See [contributing guidelines (Chinese)](CONTRIBUTING.md).

Original Foldpin application code and build scripts are licensed under **GPL-3.0-only**, without warranty. See [LICENSE](LICENSE). Third-party code, themes, and Unicode data retain their own terms; see [ThirdPartyNotices.txt](macOS/Foldpin/ThirdPartyNotices.txt). Private research, design references, and marketing archives are excluded from the public source tree.

## Repository guide

| Path | Contents |
| --- | --- |
| [macOS](macOS/README.md) | Native app, resources, and tests |
| [scripts](scripts) | Packaging, checks, and resource generation |
| [docs/engineering](docs/engineering) | Implementation details and validation records |

Most engineering documents are currently in Chinese. See the repository cleanup record before reusing an older clone.
