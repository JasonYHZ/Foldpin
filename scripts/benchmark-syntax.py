#!/usr/bin/env python3
"""Measure the production parser, attributed text and offscreen TextKit geometry.

Creates an isolated Release package in /private/tmp; lifts only the snapshot's
length gate and cache budget to examine larger highlighted inputs. Never modifies
the app's actual limits. The larger cache prevents measuring plain-text fallback.
Usage: python3 scripts/benchmark-syntax.py /private/tmp/foldpin-syntax-benchmark.json
"""
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile
import argparse

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("output", type=pathlib.Path)
parser.add_argument("--source", type=pathlib.Path, default=pathlib.Path(__file__).resolve().parents[1])
parser.add_argument("--sizes", default="10000,24000,50000,100000,200000")
args = parser.parse_args()
sizes = [int(value) for value in args.sizes.split(",")]
assert sizes and all(100 <= value < 300_000 for value in sizes)
root = args.source.resolve()
snapshot = pathlib.Path(tempfile.mkdtemp(prefix="foldpin-syntax-benchmark-", dir="/private/tmp"))
shutil.copy2(root / "macOS/Package.swift", snapshot / "Package.swift")
shutil.copytree(root / "macOS/Foldpin", snapshot / "Foldpin")
(snapshot / "Tests").mkdir()
shutil.copy2(pathlib.Path(__file__).parent / "benchmarks/CodeSyntaxPerformance.swift", snapshot / "Tests/CodeSyntaxPerformance.swift")
engine = snapshot / "Foldpin/Core/CodeSyntaxEngine.swift"
import re
source, count = re.subn(r"static let maximumSourceLength = [\d_]+", "static let maximumSourceLength = 300_000", engine.read_text())
assert count == 1
source = source.replace("cache.totalCostLimit = 2 * 1_024 * 1_024", "cache.totalCostLimit = 64 * 1_024 * 1_024")
engine.write_text(source)
environment = dict(os.environ, DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer",
                   CLANG_MODULE_CACHE_PATH="/private/tmp/Foldpin-ModuleCache",
                   SWIFTPM_MODULECACHE_OVERRIDE="/private/tmp/Foldpin-ModuleCache",
                   FOLDPIN_SYNTAX_BENCHMARK_OUTPUT=str(args.output.resolve()),
                   FOLDPIN_SYNTAX_BENCHMARK_SIZES=",".join(map(str, sizes)))
print("Isolated snapshot: " + str(snapshot), flush=True)
result = subprocess.run(["xcrun", "swift", "test", "--disable-sandbox", "-c", "release", "--package-path", str(snapshot),
                         "--scratch-path", str(snapshot / "build"), "--filter", "codeSyntaxPerformance"], env=environment)
sys.exit(result.returncode)
