#!/usr/bin/env python3
"""One isolated native window check with synthetic notes; no installed app launch.

Usage: python3 scripts/check-library-window.py OUTPUT_DIR
Uses invisible native windows with synthetic notes. Does not register global hotkeys,
touch the clipboard, or read/write the user's note library or preferences.
"""
import json
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile

root = pathlib.Path(__file__).resolve().parents[1]
output = pathlib.Path(sys.argv[1]).resolve()
output.mkdir(parents=True, exist_ok=True)
snapshot = pathlib.Path(os.environ.get("FOLDPIN_LIBRARY_WORK") or tempfile.mkdtemp(prefix="foldpin-handoff-check-", dir="/private/tmp"))
shutil.copytree(root / "macOS/Foldpin", snapshot / "Foldpin", dirs_exist_ok=True)
(snapshot / "Tests").mkdir(exist_ok=True)
check_source = sys.argv[3] if len(sys.argv) > 3 else "LibraryWindow.swift"
shutil.copy2(root / "scripts/checks" / check_source, snapshot / "Tests/LibraryWindow.swift")
for old in (snapshot / "Tests").glob("*.swift"):
    if old.name != "LibraryWindow.swift": old.unlink()
(snapshot / "Package.swift").write_text('''// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "FoldpinCore", platforms: [.macOS("26.5")], targets: [
    .target(name: "FoldpinCore", path: "Foldpin", exclude: ["AppDelegate.swift", "FoldpinApp.swift",
        "ApplicationMenuLocalization.swift",
        "Assets.xcassets", "Localizable.xcstrings", "InfoPlist.xcstrings", "Foldpin.entitlements", "ThirdPartyNotices.txt"],
        resources: [.copy("CodeThemes"), .copy("SyntaxResources"), .copy("EmojiResources")],
        swiftSettings: [.unsafeFlags(["-default-isolation", "MainActor"])]),
    .testTarget(name: "FoldpinCoreTests", dependencies: ["FoldpinCore"], path: "Tests")], swiftLanguageModes: [.v5])
''')
note_style = snapshot / "Foldpin/Editor/NoteStyleSettings.swift"
note_style.write_text(note_style.read_text().replace("static let shared = NoteStyleSettings()",
    'static let shared = NoteStyleSettings(defaults: UserDefaults(suiteName: "Foldpin.NoteStyle.Check")!)'))
themes = snapshot / "Foldpin/Editor/CodeThemeSettings.swift"
source = themes.read_text()
assert "static let shared = CodeThemeSettings()" in source
themes.write_text(source.replace("static let shared = CodeThemeSettings()",
    'static let shared = CodeThemeSettings(directory: URL(fileURLWithPath: ProcessInfo.processInfo.environment["FOLDPIN_CHECK_DATA"]!).appendingPathComponent("themes"))'))
# Build only the helper's localization bundle; application resources stay unchanged.
localizations = snapshot / "Check.bundle"
strings = json.loads((root / "macOS/Foldpin/Localizable.xcstrings").read_text())["strings"]
for code in ["en", "zh-Hans"]:
    folder = localizations / (code + ".lproj")
    folder.mkdir(parents=True, exist_ok=True)
    lines = []
    for key, entry in strings.items():
        value = entry.get("localizations", {}).get(code, {}).get("stringUnit", {}).get("value", key)
        lines.append(json.dumps(key, ensure_ascii=False) + " = " + json.dumps(value, ensure_ascii=False) + ";")
    (folder / "Localizable.strings").write_text("\n".join(lines))
language = snapshot / "Foldpin/LanguageSettings.swift"
langsource = language.read_text().replace("static let shared = LanguageSettings()",
    'static let shared = LanguageSettings(applicationID: "Foldpin.Library.Check", resources: Bundle(path: ProcessInfo.processInfo.environment["FOLDPIN_CHECK_LOCALIZATIONS"]!)!, systemLanguages: { ["zh-Hans"] })')
if check_source == "Settings.swift":
    langsource = langsource.replace('LanguageSettings(applicationID: "Foldpin.Library.Check",', 'LanguageSettings(defaults: UserDefaults(suiteName: "Foldpin.Library.Check")!, applicationID: "Foldpin.Library.Check",')
language.write_text(langsource)
if check_source == "Settings.swift":
    for relative in ["Core/ShortcutSettings.swift", "ThemeSettings.swift"]:
        path = snapshot / "Foldpin" / relative
        content = path.read_text()
        typename = path.stem
        content = content.replace("static let shared = " + typename + "()", 'static let shared = ' + typename + '(defaults: UserDefaults(suiteName: "Foldpin.Settings.Check.Preferences")!)')
        path.write_text(content)

environment = dict(os.environ, DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer",
    CLANG_MODULE_CACHE_PATH="/private/tmp/Foldpin-ModuleCache", SWIFTPM_MODULECACHE_OVERRIDE="/private/tmp/Foldpin-ModuleCache",
    FOLDPIN_CHECK_LOCALIZATIONS=str(localizations), FOLDPIN_CHECK_DATA=str(snapshot / "data"), FOLDPIN_CHECK_OUTPUT=str(output))
command = ["xcrun", "swift", "test", "--disable-sandbox", "--no-parallel", "--package-path", str(snapshot),
    "--scratch-path", str(snapshot / "build"), "--filter", sys.argv[2] if len(sys.argv) > 2 else "libraryWindow"]
print("Isolated native check: " + str(snapshot), flush=True)
with (output / "native-check.log").open("w") as log:
    result = subprocess.run(command, env=environment, stdout=log, stderr=subprocess.STDOUT)
print((output / "native-check.log").read_text()[-5000:], flush=True)
raise SystemExit(result.returncode)
