import AppKit
import Testing
@testable import FoldpinCore

// Runs only in the temporary package created by benchmark-syntax.py. No windows
// are opened and no user note files or clipboard are accessed.
@Test @MainActor func codeSyntaxPerformance() async throws {
    let cases: [(String, CodeLanguage, String)] = [
        ("java", .java, "public class Card { private int count = 42; public String title() { return \"Foldpin\"; } }\n"),
        ("html", .html, "<div class=\"card\"><span>Foldpin</span></div><script>const count = 42;</script>\n"),
        ("js-minified", .javascript, "const a={name:'Foldpin',count:42};function f(x){return x+1;}"),
        ("json-minified", .json, "{\"name\":\"Foldpin\",\"enabled\":true,\"count\":42},")
    ]
    let sizes = ProcessInfo.processInfo.environment["FOLDPIN_SYNTAX_BENCHMARK_SIZES"]?
        .split(separator: ",").compactMap { Int($0) } ?? [10_000, 24_000, 50_000, 100_000, 200_000]
    let clock = ContinuousClock()
    func ms(_ start: ContinuousClock.Instant) -> Double {
        let duration = start.duration(to: clock.now).components
        return Double(duration.seconds) * 1000 + Double(duration.attoseconds) / 1e15
    }
    var records: [[String: Any]] = []
    for (name, language, line) in cases {
        _ = await CodeSyntaxEngine.shared.analyze(line, language: language)
        for size in sizes {
            for trial in 0..<2 {
                var code = String(repeating: line, count: (size - 1) / line.utf16.count)
                code += String(repeating: " ", count: size - code.utf16.count - 1) + String(trial)
                let start = clock.now
                let analysis = await CodeSyntaxEngine.shared.analyze(code, language: language)
                let parse = ms(start)
                #expect(!analysis.spans.isEmpty)
                #expect(CodeSyntaxEngine.shared.cached(code, language: language)?.spans.count == analysis.spans.count)
                let content = NoteContent(blocks: [NoteBlock(kind: .code, text: code, language: language)])
                let renderStart = clock.now
                let rendered = BlockTextCodec.render(content, color: .labelColor, width: 400, cachedSyntaxOnly: true, image: { _ in nil })
                let render = ms(renderStart)
                #expect(rendered.string == code)
                let editor = PaperTextView(usingTextLayoutManager: true)
                editor.frame = NSRect(x: 0, y: 0, width: 440, height: 500)
                editor.textContainerInset = NSSize(width: 20, height: 16)
                editor.textContainer?.size = NSSize(width: 400, height: 1_000_000)
                editor.textContainer?.widthTracksTextView = true
                editor.isRichText = true
                let scroll = NSScrollView(frame: editor.frame)
                scroll.documentView = editor
                let installStart = clock.now
                editor.configure(content: content)
                let install = ms(installStart)
                let geometryStart = clock.now
                let surfaces = editor.codeBlockSurfaces()
                let geometry = ms(geometryStart)
                #expect(surfaces.count == 1)
                let steadyStart = clock.now
                _ = editor.codeBlockSurfaces()
                let steady = ms(steadyStart)
                records.append(["case": name, "utf16": size, "trial": trial, "tokens": analysis.spans.count,
                                "parse_ms": parse, "render_ms": render, "install_ms": install,
                                "geometry_ms": geometry, "steady_geometry_ms": steady])
                print("BENCH \(name) \(size) tokens=\(analysis.spans.count) parse=\(Int(parse)) render=\(Int(render)) install=\(Int(install)) geometry=\(Int(geometry)) steady=\(Int(steady))")
            }
        }
    }
    let path = try #require(ProcessInfo.processInfo.environment["FOLDPIN_SYNTAX_BENCHMARK_OUTPUT"])
    try JSONSerialization.data(withJSONObject: records, options: [.prettyPrinted, .sortedKeys])
        .write(to: URL(fileURLWithPath: path))
}
