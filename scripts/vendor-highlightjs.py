#!/usr/bin/env python3
"""Bundle reviewed highlight.js CommonJS modules without npm/build dependencies.

Usage: python3 scripts/vendor-highlightjs.py /path/to/extracted/npm/package
Download highlight.js-11.11.1.tgz from the URL recorded in the generated manifest.
"""
import hashlib
import json
import pathlib
import sys

source = pathlib.Path(sys.argv[1])
destination = pathlib.Path(__file__).resolve().parents[1] / "macOS/Foldpin/SyntaxResources"
version = json.loads((source / "package.json").read_text())["version"]
assert version == "11.11.1", "Review the bridge and grammar changes before upgrading."
languages = ["xml", "swift", "java", "javascript", "typescript", "python", "json", "sql", "bash",
             "css", "c", "cpp", "csharp", "go", "rust", "kotlin", "ruby", "php", "php-template",
             "yaml", "markdown", "diff", "ini", "objectivec", "lua", "dart", "r", "makefile",
             "dockerfile", "graphql"]
modules = ["core"] + ["languages/" + name for name in languages]
chunks = ["// highlight.js " + version + "; BSD-3-Clause; see LICENSE-highlight.js.txt\n",
          "var FoldpinHighlightJS = (function () {\nconst factories = Object.create(null);\n"]
checksums = {}
for module in modules:
    raw = (source / "lib" / (module + ".js")).read_bytes()
    checksums["lib/" + module + ".js"] = hashlib.sha256(raw).hexdigest()
    chunks.append("factories[" + json.dumps(module) + "] = function(module, exports, require) {\n")
    chunks.append(raw.decode("utf-8"))
    chunks.append("\n};\n")
chunks.append("""const loaded = Object.create(null);
function require(name) {
  if (!factories[name]) throw new Error('Unavailable bundled module: ' + name);
  if (!loaded[name]) {
    const module = { exports: {} };
    factories[name](module, module.exports, require);
    loaded[name] = module.exports;
  }
  return loaded[name];
}
const hljs = require('core');
""")
for language in languages:
    chunks.append("hljs.registerLanguage(" + json.dumps(language) + ", require(" + json.dumps("languages/" + language) + "));\n")
chunks.append("return hljs;\n})();\n")
destination.mkdir(parents=True, exist_ok=True)
bundle = "".join(chunks).encode("utf-8")
(destination / "highlight.js").write_bytes(bundle)
(destination / "LICENSE-highlight.js.txt").write_bytes((source / "LICENSE").read_bytes())
manifest = {"name": "highlight.js", "version": version,
            "source": "https://registry.npmjs.org/highlight.js/-/highlight.js-11.11.1.tgz",
            "repository": "https://github.com/highlightjs/highlight.js/tree/11.11.1",
            "license": "BSD-3-Clause", "languages": languages,
            "bundleSHA256": hashlib.sha256(bundle).hexdigest(), "upstreamSHA256": checksums}
(destination / "highlight-manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
print(str(len(bundle)) + " bytes; " + str(len(languages)) + " grammars")
