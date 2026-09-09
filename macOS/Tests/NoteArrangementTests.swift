import AppKit
import Testing
@testable import FoldpinCore

@Test func arrangementPacksMixedNotesPerScreenWithoutResizing() {
    let screens = [CGRect(x: 0, y: 24, width: 1200, height: 850), CGRect(x: -1200, y: 874, width: 1200, height: 850)]
    let items = [
        NoteArrangement.Item(id: UUID(), frame: CGRect(x: 70, y: 100, width: 360, height: 340)),
        NoteArrangement.Item(id: UUID(), frame: CGRect(x: 80, y: 150, width: 300, height: 52)),
        NoteArrangement.Item(id: UUID(), frame: CGRect(x: 120, y: 180, width: 420, height: 400)),
        NoteArrangement.Item(id: UUID(), frame: CGRect(x: -1000, y: 900, width: 360, height: 340))
    ]
    let result = NoteArrangement.placements(for: items, screens: screens)
    #expect(result.count == items.count)
    for placement in result {
        #expect(placement.before.size == placement.after.size)
        let screen = NoteArrangement.screenIndex(for: placement.before, screens: screens)!
        #expect(screens[screen].contains(placement.after))
    }
    for i in result.indices {
        for j in result.indices where j > i { #expect(!result[i].after.intersects(result[j].after)) }
    }
    let repeated = NoteArrangement.placements(for: result.map { .init(id: $0.id, frame: $0.after) }, screens: screens)
    #expect(repeated.map(\.after) == result.map(\.after))
}

@Test func arrangementOverflowAndOversizedNotesKeepSizeAndReachableHeaders() {
    let screen = CGRect(x: -800, y: 80, width: 800, height: 600)
    let items = (0..<20).map { _ in NoteArrangement.Item(id: UUID(), frame: CGRect(x: -780, y: 120, width: 360, height: 340)) }
    let packed = NoteArrangement.placements(for: items, screens: [screen])
    #expect(packed.count == 20)
    #expect(packed[2].after != packed[0].after)
    #expect(Set(packed.map { "\($0.after.minX),\($0.after.minY)" }).count > 2)
    for placement in packed {
        #expect(placement.after.size == placement.before.size && screen.contains(placement.after))
    }
    let huge = NoteArrangement.Item(id: UUID(), frame: CGRect(x: -780, y: 90, width: 1000, height: 900))
    let result = NoteArrangement.placements(for: [huge], screens: [screen])[0]
    #expect(result.after.size == huge.frame.size)
    #expect(screen.contains(CGPoint(x: result.after.minX + 40, y: result.after.maxY - 26)))
    #expect(NoteArrangement.placements(for: items, screens: []).isEmpty)
}

@Test func arrangementUndoIgnoresManualChangesAndFitsDisconnectedDisplay() throws {
    let before = CGRect(x: -1000, y: 1100, width: 360, height: 52)
    let after = CGRect(x: -1184, y: 1620, width: 360, height: 52)
    let placement = NoteArrangement.Placement(id: UUID(), before: before, after: after)
    let screens = [CGRect(x: 0, y: 24, width: 1200, height: 850), CGRect(x: -1200, y: 874, width: 1200, height: 850)]
    #expect(NoteArrangement.undoFrame(for: placement, current: after, screens: screens) == before)
    #expect(NoteArrangement.undoFrame(for: placement, current: after.offsetBy(dx: 1, dy: 0), screens: screens) == nil)
    let recovered = try #require(NoteArrangement.undoFrame(for: placement, current: after, screens: [screens[0]]))
    #expect(recovered.size == before.size && screens[0].contains(recovered))
}

@Test @MainActor func arrangementPersistsAndRestoresCollapsedGeometryWithoutChangingContent() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = NoteStore(file: NoteFile(url: root.appendingPathComponent("note.json")))
    store.edit(NoteContent(blocks: [NoteBlock(kind: .heading, text: "保留 🌿"), NoteBlock(kind: .code, text: "let n = 1", language: .swift)]))
    store.setColor(.blue)
    store.setPinned(true)
    store.setFrame(CGRect(x: -700, y: 1000, width: 360, height: 480))
    store.setCollapsed(true)
    #expect(store.flush())
    let original = store.document
    let moved = CGRect(x: -1184, y: 1600, width: 360, height: 52)
    #expect(store.saveArrangedWindowFrame(moved, collapsed: true))
    var expected = original
    expected.frame = NoteFrame(NoteLayout.expandedFrame(window: moved, collapsed: true, rememberedHeight: 480))
    #expect(try store.file.load() == expected)
    let restarted = NoteStore(file: store.file)
    #expect(restarted.document == expected)
    #expect(restarted.saveArrangedWindowFrame(NoteLayout.visibleFrame(expanded: original.frame!.rect, collapsed: true), collapsed: true))
    #expect(try store.file.load() == original)
}

@Test @MainActor func arrangementFailedSaveKeepsOldGeometryAndUnsavedContent() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = NoteStore(file: NoteFile(url: root.appendingPathComponent("note.json")))
    store.edit("必须保留的正文")
    store.setFrame(CGRect(x: 50, y: 50, width: 360, height: 340))
    let original = store.document
    try Data("blocked parent".utf8).write(to: root)
    #expect(!store.saveArrangedWindowFrame(CGRect(x: 16, y: 500, width: 360, height: 340), collapsed: false))
    #expect(store.document == original && store.isDirty && store.saveError != nil)
    try FileManager.default.removeItem(at: root)
    #expect(store.flush())
    #expect(try store.file.load() == original)
    store.setShelved(true)
    #expect(store.flush())
    let shelved = store.document
    #expect(!store.saveArrangedWindowFrame(CGRect(x: 16, y: 500, width: 360, height: 340), collapsed: false))
    #expect(store.document == shelved)
    store.setShelved(false)
    #expect(store.setDeletedAt(Date()))
    let deleted = store.document
    #expect(!store.saveArrangedWindowFrame(CGRect(x: 16, y: 500, width: 360, height: 340), collapsed: false))
    #expect(store.document == deleted)
}

@Test @MainActor func glassReadingTintPreservesEachColorWithoutAWindowFocusDependency() throws {
    #expect(NotePalette.glassReadingTint(for: .original) == nil)
    for name in [NSAppearance.Name.aqua, .darkAqua] {
        let appearance = try #require(NSAppearance(named: name))
        var colors: Set<String> = []
        for color in NoteColor.allCases where color != .original {
            var resolved: NSColor?
            appearance.performAsCurrentDrawingAppearance {
                resolved = NotePalette.glassReadingTint(for: color)?.usingColorSpace(.sRGB)
            }
            let tint = try #require(resolved)
            #expect(tint.alphaComponent > 0 && tint.alphaComponent < 0.3)
            #expect(max(tint.redComponent, tint.greenComponent, tint.blueComponent) - min(tint.redComponent, tint.greenComponent, tint.blueComponent) > 0.1)
            colors.insert("\(tint.redComponent),\(tint.greenComponent),\(tint.blueComponent)")
        }
        #expect(colors.count == 5)
    }
}
