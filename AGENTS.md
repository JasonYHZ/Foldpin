# Foldpin contributor instructions

Foldpin is a native macOS app built with SwiftUI, AppKit, NSTextView, and TextKit. Preserve independent note windows and the capture → pin → shelve → retrieve workflow.

- Work on `main` unless the maintainer explicitly approves another branch or worktree.
- Read the English README, Chinese README, and `macOS/README.md` before changing behavior. Engineering documents describe completed checks and their limits; historical proposals are not current requirements.
- Preserve atomic saves, recovery, per-note undo history, IME composition, shared editor identity, and explicit error handling. Never silently drop attachments or overwrite unreadable notes.
- Use temporary synthetic data for checks. Do not open the maintainer's real library, change system preferences, or record audio without specific authorization.
- Maintain all eight interface languages and microphone descriptions. Run `python3 scripts/check-localizations.py` after localization changes.
- Use the native project and Swift package under `macOS/`; do not initialize a nested repository.
- Public documentation is English-first, with a separate `README.zh-CN.md`. Preserve GPL-3.0-only and third-party notices.
- Do not commit private research, chat links, screenshots of personal data, local paths, credentials, build caches, or `dist/` artifacts.
- Build public packages with `scripts/package-release.py` from a clean commit. Verify both architectures, signatures, corresponding source, translations, checksums, and absence of personal paths. Compilation does not establish Intel hardware, Gatekeeper, accessibility, or live-device validation.
- Repository visibility, destructive remote actions, and release publication require maintainer authorization. The repository remains private during the current cleanup; Homebrew follows the public launch.

The maintainer authorized cleanup of public files and Git history on 2026-11-06. Original private material is preserved outside this repository. Do not merge an old clone back into the cleaned history.
