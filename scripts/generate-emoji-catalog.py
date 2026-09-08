#!/usr/bin/env python3
"""Generate the offline picker catalog from pinned Unicode/CLDR source files.

Download SOURCES into a temporary directory, then run:
  python3 scripts/generate-emoji-catalog.py /path/to/source-directory
This generator does not access the network or any note files.
"""
import argparse
import collections
import hashlib
import json
from pathlib import Path
import re
import xml.etree.ElementTree as ET

SOURCES = {
    "emoji-test.txt": "https://www.unicode.org/Public/emoji/16.0/emoji-test.txt",
    "zh.xml": "https://raw.githubusercontent.com/unicode-org/cldr/release-46/common/annotations/zh.xml",
    "zh-derived.xml": "https://raw.githubusercontent.com/unicode-org/cldr/release-46/common/annotationsDerived/zh.xml",
    "LICENSE.txt": "https://raw.githubusercontent.com/unicode-org/cldr/release-46/LICENSE",
}
GROUPS = {
    "Smileys & Emotion": "smileys", "People & Body": "people",
    "Animals & Nature": "nature", "Food & Drink": "food",
    "Travel & Places": "travel", "Activities": "activities",
    "Objects": "objects", "Symbols": "symbols", "Flags": "flags",
}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source_directory", type=Path)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    output = root / "macOS/Foldpin/EmojiResources"
    output.mkdir(parents=True, exist_ok=True)
    annotations = {}
    for file in ("zh.xml", "zh-derived.xml"):
        for node in ET.parse(args.source_directory / file).iter("annotation"):
            values = annotations.setdefault(node.attrib["cp"].replace("\ufe0f", ""), {})
            values[node.attrib.get("type", "keywords")] = node.text or ""
    entries = []
    group = None
    for line in (args.source_directory / "emoji-test.txt").read_text().splitlines():
        if line.startswith("# group: "):
            group = GROUPS.get(line.removeprefix("# group: "))
        match = re.match(r"^([0-9A-F ]+)\s*; fully-qualified\s*# \S+ E[\d.]+ (.+)$", line)
        if not match or group is None:
            continue
        points = [int(value, 16) for value in match[1].split()]
        # Keep base choices without repeating each person in five skin tones.
        # The picker still accepts a complete custom/skin-tone emoji in search.
        if any(0x1F3FB <= value <= 0x1F3FF for value in points):
            continue
        emoji = "".join(chr(value) for value in points)
        chinese = annotations.get(emoji.replace("\ufe0f", ""), {})
        entries.append({"emoji": emoji, "category": group, "name": match[2],
                        "chineseName": chinese.get("tts", ""),
                        "keywords": chinese.get("keywords", "").replace(" | ", " ")})
    assert len(entries) > 1800 and len({entry["emoji"] for entry in entries}) == len(entries)
    data = (json.dumps(entries, ensure_ascii=False, separators=(",", ":")) + "\n").encode()
    (output / "emoji-catalog.json").write_bytes(data)
    (output / "Unicode-LICENSE.txt").write_bytes((args.source_directory / "LICENSE.txt").read_bytes())
    manifest = {"emojiVersion": "16.0", "cldrVersion": "46", "count": len(entries),
                "catalogSHA256": hashlib.sha256(data).hexdigest(),
                "sources": [{"file": name, "url": url,
                             "sha256": hashlib.sha256((args.source_directory / name).read_bytes()).hexdigest()}
                            for name, url in SOURCES.items()]}
    (output / "emoji-sources.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n")
    print(f"{len(entries)} emoji, {len(data):,} bytes")
    print(dict(collections.Counter(entry["category"] for entry in entries)))
    print("Missing Chinese names:", sum(not entry["chineseName"] for entry in entries))


if __name__ == "__main__":
    main()
