#!/usr/bin/env python3
"""Check translation coverage and printf argument safety without launching Foldpin."""
import collections
import argparse
import json
import pathlib
import re
import sys
import subprocess

ROOT = pathlib.Path(__file__).resolve().parents[1]
LANGUAGES = ("en", "zh-Hans", "zh-Hant", "ja", "ko", "de", "fr", "es")
ARGUMENT = re.compile(r"%(?:[1-9]\d*\$)?(?:lld|llu|ld|lu|@|d|u|f|s)")


def arguments(value):
    return collections.Counter(re.sub(r"^%[1-9]\d*\$", "%", item) for item in ARGUMENT.findall(value))


def check(path, keys=None):
    catalog = json.loads(path.read_text())
    errors = []
    for key, entry in catalog["strings"].items():
        if keys is not None and key not in keys:
            continue
        for language in LANGUAGES:
            unit = entry.get("localizations", {}).get(language, {}).get("stringUnit")
            if unit is None:
                # English is the source language; these strings are language-neutral.
                if language == "en" or key in ("", "%lld / %lld", "Foldpin"):
                    continue
                errors.append(f"{language}: missing {key!r}")
                continue
            value = unit["value"]
            if key and not value:
                errors.append(f"{language}: empty {key!r}")
            if arguments(key) != arguments(value):
                errors.append(f"{language}: argument mismatch {key!r}")
    return errors


def check_compiled(app):
    errors = []
    checked = 0
    for table, selected in (("Localizable", None), ("InfoPlist", {"NSMicrophoneUsageDescription"})):
        catalog = json.loads((ROOT / "macOS/Foldpin" / f"{table}.xcstrings").read_text())
        for language in LANGUAGES:
            path = app / "Contents/Resources" / f"{language}.lproj" / f"{table}.strings"
            if not path.is_file():
                errors.append(f"Missing compiled resource: {path}")
                continue
            # plutil also handles the UTF-16 .strings files emitted by Xcode.
            result = subprocess.run(["plutil", "-convert", "json", "-o", "-", str(path)],
                                    check=True, capture_output=True, text=True)
            compiled = json.loads(result.stdout)
            for key, entry in catalog["strings"].items():
                if selected is not None and key not in selected:
                    continue
                unit = entry.get("localizations", {}).get(language, {}).get("stringUnit", {})
                expected = unit.get("value", key)
                actual = compiled.get(key, key)
                # Source-language format strings may be emitted without argument positions.
                normalize = lambda value: re.sub(r"%[1-9]\d*\$", "%", value)
                if normalize(actual) != normalize(expected):
                    errors.append(f"{language}: compiled {table} mismatch {key!r}")
                checked += 1
    return errors, checked


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=pathlib.Path, help="Also verify a built .app's language resources")
    options = parser.parse_args()
    resources = ROOT / "macOS/Foldpin"
    errors = check(resources / "Localizable.xcstrings")
    errors += check(resources / "InfoPlist.xcstrings", {"NSMicrophoneUsageDescription"})
    if options.app:
        compiled_errors, count = check_compiled(options.app)
        errors += compiled_errors
    if errors:
        print("\n".join(errors), file=sys.stderr)
        sys.exit(1)
    print(f"Translation coverage and format arguments passed for {len(LANGUAGES)} languages.")
    if options.app:
        print(f"{count} compiled translations verified without launching the app.")
