// Foldpin adapter for highlight.js 11.11.1. Only source strings enter this API;
// they are never evaluated. No DOM, HTML importer, CSS, or network is involved.
// _emitter is a private upstream API: the version is pinned and range/source
// round-trip tests must pass before upgrading it.
// Keep explicit JSON script tags in the JSON theme scope. The upstream XML
// grammar otherwise treats every script body as JavaScript or XML.
{
  const hljs = FoldpinHighlightJS;
  const xml = hljs.getLanguage('xml');
  const script = xml.contains.find(rule => rule.begin && rule.begin.source === '<script(?=\\s|>)');
  if (script) {
    const jsonScript = hljs.inherit(script, {
      begin: /<script(?=\s)(?=[^>]*\btype\s*=\s*["'](?:application\/(?:ld\+)?json|importmap)["'])/,
      starts: hljs.inherit(script.starts, { subLanguage: 'json' })
    });
    hljs.registerLanguage('xml', () => hljs.inherit(xml, { contains: [jsonScript].concat(xml.contains) }));
  }
}

function foldpinLanguageHint(sample) {
  // Short sticky-note snippets give statistical detection little context. These
  // high-confidence entry points preserve useful existing behavior; all token
  // parsing and fallback detection still belong to the upstream engine.
  if (/^\s*(?:<!doctype\s+html|<!--[\s\S]*?-->|<[a-z][\w-]*(?:\s+[^<>]*=|>[^]*<\/))/i.test(sample)) return 'xml';
  if (/^\s*[\[{]\s*"[^"\n]+"\s*:/.test(sample)) return 'json';
  if (/^#![^\n]*\bpython\d?\b/.test(sample)) return 'python';
  if (/^#![^\n]*\b(?:ba|z|da)?sh\b/.test(sample)) return 'bash';
  const masked = sample.replace(/\/\/[^\n]*|\/\*[\s\S]*?(?:\*\/|$)|"""[\s\S]*?(?:"""|$)|'''[\s\S]*?(?:'''|$)|"(?:\\.|[^"\\])*"?|'(?:\\.|[^'\\])*'?|`(?:\\.|[^`\\])*`?/g, ' ');
  if (!masked.trim()) return 'plain';
  // Distinctive language markers must precede shared words such as func,
  // function, public class and interface. Otherwise the fast path can override
  // the mature engine with the wrong language (Go → Swift, PHP → JavaScript).
  if (/^\s*<\?php\b/i.test(sample)) return 'php';
  if (/^\s*#import\s+[<"]|@(?:interface|implementation)\s+\w+/m.test(masked)) return 'objectivec';
  if (/\busing\s+System\b|\bConsole\.Write(?:Line)?\s*\(/.test(masked)) return 'csharp';
  if (/^\s*package\s+\w+\s*\n/m.test(masked) && /\bfunc\s+(?:\([^)]*\)\s*)?\w+\s*\(/.test(masked)) return 'go';
  if (/\bfun\s+\w+\s*\(|\bdata\s+class\s+\w+\s*\(/.test(masked)) return 'kotlin';
  if (/^\s*(?:local\s+\w+\s*=|local\s+function\s+\w+)/m.test(masked) && /\bend\b/.test(masked)) return 'lua';
  if (/\bfn\s+\w+\s*\(/.test(masked) && /\blet\s+mut\b|\b(?:println|vec)!|->|&(?:mut\s+)?str\b/.test(masked)) return 'rust';
  if (/^\s*#include\s+</m.test(masked)) {
    if (/\bstd::|\btemplate\s*<|#include\s*<(?:iostream|vector|string|map|memory)>/.test(masked)) return 'cpp';
    if (/#include\s*<(?:stdio|stdlib|string|stdint|stdbool|stddef)\.h>/.test(masked)) return 'c';
  }
  if (/^\s*import\s+['"](?:dart:|package:)/m.test(sample) ||
      /\bvoid\s+main\s*\(/.test(masked) && /\bfinal\s+\w+\s*=/.test(masked) && /\bprint\s*\(/.test(masked)) return 'dart';
  if (/^\s*(?:query|mutation|subscription)\s+\w+(?:\s*\([^]*?\))?\s*\{/.test(masked)) return 'graphql';
  // Prose-like formats stay out of the statistical candidate pool, but clear
  // file structure is sufficient to recognize them without guessing at prose.
  if (/^@@ -\d+(?:,\d+)? \+\d+(?:,\d+)? @@/m.test(sample) && /^[-+][^\n]+/m.test(sample)) return 'diff';
  if (/^\s*\[[\w.-]+\]\s*$/m.test(sample) && /^\s*[\w.-]+\s*=/m.test(masked)) return 'ini';
  if (/^[\w./%-]+\s*:[^\n]*\n\t\S/m.test(sample)) return 'makefile';
  if (/^#{1,6} \S/m.test(sample) && /\*\*[^*\n]+\*\*|^```\w*/m.test(sample)) return 'markdown';
  if (/\b\w+\s*<-\s*(?:c|data\.frame|seq|rep)\s*\(/.test(masked)) return 'r';
  const swift = /\b(?:import\s+(?:SwiftUI|Foundation)|func\s+\w+\s*\(|struct\s+\w+\s*\{\s*var\s+\w+\s*:)/.test(masked);
  const python = /\bdef\s+\w+\s*\([^)]*\)\s*:|^\s*(?:from\s+\w+\s+import|import\s+(?:os|sys|numpy|pandas)\b)/m.test(masked);
  if (swift && python) return 'plain';
  if (swift) return 'swift';
  if (python) return 'python';
  if (/\b(?:package\s+[\w.]+\s*;|import\s+java\.|System\.out\.|public\s+(?:class|record)\s+\w+|new\s+(?:ArrayList|HashMap)\s*<)|@Override\b/.test(masked)) return 'java';
  if (/\binterface\s+\w+|\btype\s+\w+\s*=|:\s*(?:number|string|boolean|unknown)\b/.test(masked)) return 'typescript';
  if (/\bconst\s+\w+\s*=|\bfunction\s+\w+\s*\(|\bconsole\.(?:log|warn|error)\s*\(/.test(masked)) return 'javascript';
  if (/^\s*(?:select\b[^]*\bfrom\b|insert\s+into\b[^]*\bvalues\b|update\b[^]*\bset\b|delete\s+from\b|create\s+table\b)/i.test(masked)) return 'sql';
  if (/^\s*(?:curl\s+-|git\s+(?:status|diff|log|add|commit|push|pull|clone)\b|echo\s+)/.test(masked)) return 'bash';
  return undefined;
}

function foldpinDetect(sample, candidates) {
  const hljs = FoldpinHighlightJS;
  // Strict JSON is unambiguous even when its relevance score is small.
  if (/^\s*[\[{]/.test(sample)) {
    try { JSON.parse(sample); return 'json'; } catch (_) { /* incomplete input */ }
  }
  const hint = foldpinLanguageHint(sample);
  if (hint) return hint;
  function classify(text) {
    const detected = hljs.highlightAuto(text, candidates);
    const margin = detected.relevance - (detected.secondBest ? detected.secondBest.relevance : 0);
    return detected.relevance >= 3 && margin >= 1 ? detected.language : undefined;
  }
  // Start with a small sample; consult the rest only when it adds needed context.
  return classify(sample.slice(0, 1024)) || (sample.length > 1024 ? classify(sample) : undefined) || 'plain';
}

function foldpinAnalyze(source, requested, candidates, maximumSampleLength) {
  const hljs = FoldpinHighlightJS;
  const language = requested === 'auto' ? foldpinDetect(source.slice(0, maximumSampleLength), candidates) : requested;
  if (!language || !hljs.getLanguage(language)) return { language: 'plain', spans: [] };
  const result = hljs.highlight(source, { language: language, ignoreIllegals: true });
  const spans = [];
  let offset = 0;
  function visit(node, scopes, embedded) {
    if (typeof node === 'string') {
      if (scopes.length && node.length) spans.push([offset, node.length, scopes[scopes.length - 1], embedded]);
      offset += node.length; // JS string length and AppKit ranges are both UTF-16.
      return;
    }
    let next = scopes;
    if (node.scope) {
      if (node.scope.startsWith('language:')) {
        embedded = node.scope.slice(9);
        next = [];
      } else { next = scopes.concat(node.scope); }
    }
    for (const child of node.children || []) visit(child, next, embedded);
  }
  visit(result._emitter.rootNode, [], language);
  if (offset !== source.length) throw new Error('Highlight token/source length mismatch');
  return { language: language, spans: spans };
}
