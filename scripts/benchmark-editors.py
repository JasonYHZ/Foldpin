#!/usr/bin/env python3
"""Isolated native multi-paper benchmark; never launches the installed Foldpin.

Usage: python3 scripts/benchmark-editors.py OUTPUT_DIR [--source ROOT] [--visible]
Each 1/10/30-paper and paper/glass sample runs in a fresh Release test process.
--visible briefly displays nonactivating, mouse-transparent synthetic windows.
No highlighter limits are changed. The harness is not part of routine tests.
"""
import argparse
import json
import os
import pathlib
import shutil
import subprocess
import tempfile

parser = argparse.ArgumentParser()
parser.add_argument("output", type=pathlib.Path)
parser.add_argument("--source", type=pathlib.Path, default=pathlib.Path(__file__).resolve().parents[1])
parser.add_argument("--visible", action="store_true")
args = parser.parse_args()
args.output = args.output.resolve()
args.output.mkdir(parents=True, exist_ok=True)
snapshot = pathlib.Path(tempfile.mkdtemp(prefix="foldpin-editor-benchmark-", dir="/private/tmp"))
shutil.copytree(args.source / "macOS/Foldpin", snapshot / "Foldpin")
(snapshot / "Tests").mkdir()
shutil.copy2(pathlib.Path(__file__).parent / "benchmarks/EditorPerformance.swift", snapshot / "Tests/EditorPerformance.swift")
# Include the actual SwiftUI note, native host, glass surface and shadow in the
# temporary package, without the app delegate, hotkeys or installed app lifecycle.
(snapshot / "Package.swift").write_text('''// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "FoldpinCore", platforms: [.macOS("26.5")], targets: [
    .target(name: "FoldpinCore", path: "Foldpin", exclude: ["AppDelegate.swift", "FoldpinApp.swift",
        "AppearanceSettingsView.swift", "ApplicationMenuLocalization.swift", "CodeThemeSettingsView.swift",
        "GlobalShortcut.swift", "ShelfView.swift", "PaperWindowController.swift", "PaperPanel.swift", "Assets.xcassets", "Localizable.xcstrings", "ThirdPartyNotices.txt"],
        sources: ["Core", "Editor", "LanguageSettings.swift", "ThemeSettings.swift", "NoteEditor.swift",
            "ContentView.swift", "NoteAppearance.swift", "NoteWindowSurface.swift", "NoteWindowDecoration.swift"],
        resources: [.copy("CodeThemes"), .copy("SyntaxResources")],
        swiftSettings: [.unsafeFlags(["-default-isolation", "MainActor"])]),
    .testTarget(name: "FoldpinCoreTests", dependencies: ["FoldpinCore"], path: "Tests")], swiftLanguageModes: [.v5])
''')
# Keep imported-theme discovery inside the synthetic data directory as well.
themes = snapshot / "Foldpin/Editor/CodeThemeSettings.swift"
source = themes.read_text()
assert "static let shared = CodeThemeSettings()" in source
themes.write_text(source.replace("static let shared = CodeThemeSettings()",
    'static let shared = CodeThemeSettings(directory: URL(fileURLWithPath: ProcessInfo.processInfo.environment["FOLDPIN_BENCH_DATA"]!).appendingPathComponent("themes"))'))
environment = dict(os.environ, DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer",
    CLANG_MODULE_CACHE_PATH="/private/tmp/Foldpin-ModuleCache",
    SWIFTPM_MODULECACHE_OVERRIDE="/private/tmp/Foldpin-ModuleCache")
command = ["xcrun", "swift", "test", "--disable-sandbox", "-c", "release", "--package-path", str(snapshot),
           "--scratch-path", str(snapshot / "build"), "--filter", "multiPaperPerformance"]
print("Isolated snapshot: " + str(snapshot), flush=True)
records = []
for count in (1, 10, 30):
    for material in ("paper", "translucent"):
        name = f"{count}-{material}"
        data = snapshot / name
        data.mkdir()
        output = args.output / (name + ".json")
        environment.update(FOLDPIN_BENCH_DATA=str(data), FOLDPIN_BENCH_COUNT=str(count),
            FOLDPIN_BENCH_MATERIAL=material, FOLDPIN_BENCH_VISIBLE="1" if args.visible else "0",
            FOLDPIN_BENCH_OUTPUT=str(output))
        with (args.output / (name + ".log")).open("w") as log:
            result = subprocess.run(command, env=environment, stdout=log, stderr=subprocess.STDOUT)
        if result.returncode:
            print((args.output / (name + ".log")).read_text()[-9000:], flush=True)
            raise SystemExit(result.returncode)
        record = json.loads(output.read_text())
        records.append(record)
        print(json.dumps(record, ensure_ascii=False), flush=True)
        if "--skip-build" not in command:
            command.append("--skip-build")
(args.output / "results.json").write_text(json.dumps(records, indent=2, ensure_ascii=False) + "\n")
