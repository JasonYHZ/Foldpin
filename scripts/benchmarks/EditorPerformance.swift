import AppKit
import SwiftUI
import QuartzCore
import Darwin
import Testing
@testable import FoldpinCore

@MainActor private func memory() -> [String: Double] {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout.size(ofValue: info) / MemoryLayout<integer_t>.size)
    let result = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    precondition(result == KERN_SUCCESS)
    return ["footprint_mib": Double(info.phys_footprint) / 1_048_576,
            "resident_mib": Double(info.resident_size) / 1_048_576]
}

@MainActor private func findEditor(_ view: NSView) -> PaperTextView? {
    if let editor = view as? PaperTextView { return editor }
    return view.subviews.lazy.compactMap { findEditor($0) }.first
}

@MainActor private final class SamplePaper {
    let store: NoteStore
    let panel: NSPanel
    let shadow = NoteShadowWindow()
    let editor: PaperTextView
    let tableID: UUID

    init(index: Int, directory: URL, visible: Bool) throws {
        let table = NoteBlock(kind: .table, table: NoteTable(rows: (0..<12).map { ["Row \($0)", "value", "中文 🌿"] }))
        tableID = table.id
        let html = String(repeating: "<div class=\"card\"><span>Note \(index)</span></div><script>const n = 42;</script>\n", count: 55)
        let content = NoteContent(blocks: [NoteBlock(text: "Editable note \(index)"),
            NoteBlock(kind: .code, text: html, language: .html), table,
            NoteBlock(kind: .heading, text: "Details")] + (0..<16).map { NoteBlock(text: "Paragraph \($0): native text 中文 🌿.") })
        let file = NoteFile(url: directory.appendingPathComponent("note-\(index).json"))
        var document = NoteDocument()
        document.content = content
        try file.save(document)
        store = NoteStore(file: file)
        let root = ContentView(store: store, onPin: {}, onCollapse: {}, onShelve: {}, onRetryLoad: {}, onRevealError: {})
        let hosting = TransparentNoteHostingView(rootView: root)
        let surface = NoteWindowSurface(content: hosting)
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let x = screen.minX + 24 + CGFloat(index % 10) * min(65, max(12, (screen.width - 500) / 10))
        let y = screen.maxY - 480 - CGFloat(index / 10) * 65
        panel = NSPanel(contentRect: NSRect(x: x, y: y, width: 440, height: 420),
                        styleMask: [.borderless, .nonactivatingPanel, .resizable], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.contentView = surface
        surface.layoutSubtreeIfNeeded()
        hosting.layoutSubtreeIfNeeded()
        editor = try #require(findEditor(surface))
        if visible { panel.orderFrontRegardless(); shadow.show(below: panel) }
        panel.displayIfNeeded()
    }

    func close() {
        editor.syntaxTask?.cancel()
        _ = store.flush()
        panel.removeChildWindow(shadow)
        shadow.orderOut(nil)
        panel.orderOut(nil)
        panel.contentView = nil
        panel.close()
        shadow.close()
    }
}

@Test @MainActor func multiPaperPerformance() async throws {
    let env = ProcessInfo.processInfo.environment
    let count = Int(try #require(env["FOLDPIN_BENCH_COUNT"]))!
    let material = try #require(env["FOLDPIN_BENCH_MATERIAL"])
    let visible = env["FOLDPIN_BENCH_VISIBLE"] == "1"
    let directory = URL(fileURLWithPath: try #require(env["FOLDPIN_BENCH_DATA"]))
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    UserDefaults.standard.setVolatileDomain(["noteAppearance": material, "codeTheme": "github"], forName: UserDefaults.argumentDomain)
    app.appearance = NSAppearance(named: .aqua)
    let clock = ContinuousClock()
    func ms(_ start: ContinuousClock.Instant) -> Double {
        let d = start.duration(to: clock.now).components
        return Double(d.seconds) * 1000 + Double(d.attoseconds) / 1e15
    }
    func stats(_ values: [Double]) -> [String: Double] {
        let sorted = values.sorted()
        return ["median_ms": sorted[sorted.count / 2], "p95_ms": sorted[min(sorted.count - 1, Int(ceil(Double(sorted.count) * 0.95)) - 1)], "max_ms": sorted.last!]
    }
    var result: [String: Any] = ["count": count, "material": material, "visible": visible,
        "os": ProcessInfo.processInfo.operatingSystemVersionString, "physical_memory_gib": Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824,
        "reduce_transparency": NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency,
        "increase_contrast": NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast]
    result["baseline_memory"] = memory()
    let createStart = clock.now
    var papers: [SamplePaper] = []
    defer { for paper in papers { paper.close() } }
    for index in 0..<count { papers.append(try SamplePaper(index: index, directory: directory, visible: visible)) }
    result["create_ms"] = ms(createStart)
    for paper in papers { await paper.editor.syntaxTask?.value }
    try await Task.sleep(for: .milliseconds(200))
    for paper in papers { paper.panel.displayIfNeeded() }
    CATransaction.flush()
    result["ready_ms"] = ms(createStart)
    result["ready_memory"] = memory()
    result["blocks_per_note"] = papers[0].editor.content.blocks.count
    result["code_utf16_per_note"] = papers[0].editor.content.blocks[1].text.utf16.count
    // A stable active paper; all other editors/surfaces remain alive and visible.
    let active = papers.last!
    let editor = active.editor
    if visible { active.panel.orderFrontRegardless() }
    let scroll = try #require(editor.enclosingScrollView)
    editor.setSelectedRange(NSRange(location: 0, length: 0))
    var typing: [Double] = []
    for _ in 0..<80 {
        let start = clock.now
        editor.insertText("x", replacementRange: editor.selectedRange())
        active.panel.displayIfNeeded()
        typing.append(ms(start))
        try await Task.sleep(for: .milliseconds(16))
    }
    result["typing"] = stats(typing)
    var scrolling: [Double] = []
    for index in 0..<100 {
        let start = clock.now
        let offset = CGFloat(index < 50 ? index : 100 - index) * 24
        scroll.contentView.scroll(to: NSPoint(x: 0, y: offset))
        scroll.reflectScrolledClipView(scroll.contentView)
        let point = NSPoint(x: 200, y: offset + 100)
        editor.updateCodeToolbar(at: point)
        editor.updateBlockHandle(at: point)
        active.panel.displayIfNeeded()
        CATransaction.flush()
        scrolling.append(ms(start))
        try await Task.sleep(for: .milliseconds(16))
    }
    result["scrolling"] = stats(scrolling)
    editor.beginTableCellEditing(blockID: active.tableID, row: 0, column: 0)
    let cell = try #require(editor.tableCellEditor)
    var tableTyping: [Double] = []
    for _ in 0..<60 {
        let start = clock.now
        cell.insertText("x", replacementRange: cell.selectedRange())
        active.panel.displayIfNeeded()
        tableTyping.append(ms(start))
        try await Task.sleep(for: .milliseconds(16))
    }
    result["table_typing"] = stats(tableTyping)
    #expect(active.store.document.content.blocks.first?.text.hasPrefix(String(repeating: "x", count: 80)) == true)
    #expect(active.store.document.content.blocks[2].table?.rows[0][0].hasSuffix(String(repeating: "x", count: 60)) == true)
    #expect(editor.tableCellEditor === cell)
    result["edited_memory"] = memory()
    for paper in papers { #expect(paper.store.flush()) }
    for paper in papers { paper.close() }
    papers.removeAll()
    try await Task.sleep(for: .milliseconds(250))
    // 'active' is retained here intentionally; this is not a leak measurement.
    result["closed_memory"] = memory()
    try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        .write(to: URL(fileURLWithPath: try #require(env["FOLDPIN_BENCH_OUTPUT"])))
}
