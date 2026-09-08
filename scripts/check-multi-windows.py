#!/usr/bin/env python3
"""One isolated native window check with synthetic notes; no installed app launch.

Usage: python3 scripts/check-multi-windows.py OUTPUT_DIR
Briefly displays two nonactivating sample papers. Does not register global hotkeys,
touch the clipboard, or read/write the user's note library or preferences.
"""
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile

root = pathlib.Path(__file__).resolve().parents[1]
output = pathlib.Path(sys.argv[1]).resolve()
output.mkdir(parents=True, exist_ok=True)
snapshot = pathlib.Path(tempfile.mkdtemp(prefix="foldpin-window-check-", dir="/private/tmp"))
shutil.copytree(root / "macOS/Foldpin", snapshot / "Foldpin")
(snapshot / "Tests").mkdir()
shutil.copy2(root / "scripts/checks/MultiWindowLifecycle.swift", snapshot / "Tests/MultiWindowLifecycle.swift")
(snapshot / "Package.swift").write_text('''// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "FoldpinCore", platforms: [.macOS("26.5")], targets: [
    .target(name: "FoldpinCore", path: "Foldpin", exclude: ["AppDelegate.swift", "FoldpinApp.swift",
        "AppearanceSettingsView.swift", "ApplicationMenuLocalization.swift", "CodeThemeSettingsView.swift",
        "GlobalShortcut.swift", "Assets.xcassets", "Localizable.xcstrings", "ThirdPartyNotices.txt"],
        resources: [.copy("CodeThemes"), .copy("SyntaxResources")],
        swiftSettings: [.unsafeFlags(["-default-isolation", "MainActor"])]),
    .testTarget(name: "FoldpinCoreTests", dependencies: ["FoldpinCore"], path: "Tests")], swiftLanguageModes: [.v5])
''')
themes = snapshot / "Foldpin/Editor/CodeThemeSettings.swift"
source = themes.read_text()
assert "static let shared = CodeThemeSettings()" in source
themes.write_text(source.replace("static let shared = CodeThemeSettings()",
    'static let shared = CodeThemeSettings(directory: URL(fileURLWithPath: ProcessInfo.processInfo.environment["FOLDPIN_CHECK_DATA"]!).appendingPathComponent("themes"))'))
environment = dict(os.environ, DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer",
    CLANG_MODULE_CACHE_PATH="/private/tmp/Foldpin-ModuleCache", SWIFTPM_MODULECACHE_OVERRIDE="/private/tmp/Foldpin-ModuleCache",
    FOLDPIN_CHECK_DATA=str(snapshot / "data"), FOLDPIN_CHECK_OUTPUT=str(output))
command = ["xcrun", "swift", "test", "--disable-sandbox", "--package-path", str(snapshot),
    "--scratch-path", str(snapshot / "build"), "--filter", "multiWindowLifecycle"]
print("Isolated native check: " + str(snapshot), flush=True)
with (output / "native-check.log").open("w") as log:
    result = subprocess.run(command, env=environment, stdout=log, stderr=subprocess.STDOUT)
print((output / "native-check.log").read_text()[-5000:], flush=True)
raise SystemExit(result.returncode)
