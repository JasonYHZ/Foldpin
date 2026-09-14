import AppKit
import SwiftUI
import Testing
import Combine
@testable import FoldpinCore

@Test @MainActor func libraryWindowLayout() async throws {
    UserDefaults.standard.setVolatileDomain(["noteAppearance": "paper"], forName: UserDefaults.argumentDomain)
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    app.appearance = NSAppearance(named: .aqua)
    _ = try #require(NSScreen.main)
    let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["FOLDPIN_CHECK_DATA"]!).appendingPathComponent(UUID().uuidString)
    let library = NoteLibrary(directory: directory)
    let samples = [
        ("📝", "这周想完成的事\n☐ 整理收纳窗口的设计\n☑ 写完第一篇开发日志\n☐ 收集第一批使用反馈\n☐ 周五留一点时间复盘", NoteColor.yellow),
        ("💻", "本地开发常用命令\nnpm run dev\nnpm run build\ngit status", NoteColor.blue),
        ("💡", "收起来之后，怎么找回？\n收纳应该是一件很轻松的事。\n\n记得颜色，记得内容的一句话，也能找到那张纸片。\n\n先把浏览和搜索做顺手，再考虑更复杂的整理。", NoteColor.pink),
        ("🎙️", "散步时想到的点子\n语音记录 · 01:24\n\n今天聊到桌面整理，回来再听一下。", NoteColor.green),
        ("📚", "编辑体验观察\n好的工具应该让人忘记工具本身。\n\n粘贴进来就能继续写。\n想调整顺序时，拖一下就好。", NoteColor.purple),
        ("☕", "周末的几个小计划\n去逛逛附近的新书店\n找一家安静的咖啡馆\n把上次没看完的书带上", NoteColor.yellow),
        ("🌿", "把事情记下来\n留一点空间，让新的想法进来。", NoteColor.green),
        ("🛠️", "窗口交互细节\n拖动上沿移动窗口\n折叠后保留内容线索\n重新打开时回到原来的纸片", NoteColor.blue)]
    for (index, sample) in samples.enumerated() {
        let entry = try #require(index == 0 ? library.entries.first : library.createNote())
        entry.store.edit(sample.1); entry.store.setIcon(sample.0); entry.store.setColor(sample.2)
        entry.store.setShelved(index > 1)
        #expect(entry.store.setFavorite(index == 1 || index == 4))
        var fixture = entry.store.document
        fixture.modifiedAt = Calendar.current.date(byAdding: .day, value: -[0, 1, 3, 7, 10, 20, 30, 45][index], to: Date())!
        try entry.store.file.save(fixture); entry.store.reload()
    }
    var controllers: [UUID: PaperWindowController] = [:]
    let owner = ShelfPreviewWindow(library: library, resolve: { id in
        if let existing = controllers[id] { return existing }
        guard let entry = library.entry(id) else { return nil }
        let controller = PaperWindowController(entry: entry); controllers[id] = controller; return controller
    }, onNew: {}, onRetry: {}, onRestore: { _ in }, existingController: { controllers[$0] }, onPermanentlyDeleted: { controllers.removeValue(forKey: $0) })
    defer { for c in controllers.values { c.dispose() }; owner.window.orderOut(nil) }
    _ = owner.collections.create("Foldpin 开发"); _ = owner.collections.create("文章与反馈")
    let cid = try #require(owner.collections.collections.first?.id)
    #expect(owner.collections.setMembership(Set(library.entries.prefix(4).map(\.id)), collection: cid, included: true))
    owner.window.setContentSize(NSSize(width: 1240, height: 780))
    owner.window.alphaValue = 0
    owner.window.orderFrontRegardless()
    func capture(_ name: String) throws {
        // Native compositor-owned sidebar glass is not reproduced by cacheDisplay.
        // These invisible-window images verify geometry and content only.
        owner.window.contentView?.superview?.layoutSubtreeIfNeeded()
        let view = try #require(owner.window.contentView?.superview)
        view.layoutSubtreeIfNeeded()
        view.layoutSubtreeIfNeeded()
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let output = URL(fileURLWithPath: ProcessInfo.processInfo.environment["FOLDPIN_CHECK_OUTPUT"]!)
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent(name + ".png"))
    }
    try await Task.sleep(for: .milliseconds(250))
    let split = try #require(owner.window.contentViewController as? NSSplitViewController)
    #expect(split.splitViewItems.first?.behavior == .sidebar)
    #expect(split.splitViewItems.first?.allowsFullHeightLayout == true)
    #expect(owner.window.toolbar?.items.contains { $0 is NSTrackingSeparatorToolbarItem } == true)
    #expect(controllers.isEmpty)
    let searchItem = try #require(owner.window.toolbar?.items.first { $0.itemIdentifier.rawValue == "shelf.search" })
    #expect(searchItem.view == nil && searchItem.image != nil)
    let sideView = split.splitViewItems[0].viewController.view
    #expect(sideView.bounds.width >= 210)
    let titleView = try #require(owner.window.toolbar?.items.first { $0.itemIdentifier.rawValue == "shelf.title" }?.view)
    let sidebarRight = sideView.convert(sideView.bounds, to: nil).maxX
    #expect(titleView.convert(titleView.bounds, to: nil).minX >= sidebarRight)
    if let bitmap = sideView.bitmapImageRepForCachingDisplay(in: sideView.bounds) {
        sideView.cacheDisplay(in: sideView.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: ProcessInfo.processInfo.environment["FOLDPIN_CHECK_OUTPUT"]!).appendingPathComponent("00-sidebar.png"))
    }
    let initialDetail = try #require(split.splitViewItems[1].viewController.children.first as? NSSplitViewController)
    #expect(!initialDetail.splitViewItems[1].isCollapsed)
    let initialBrowserWidth = initialDetail.splitViewItems[0].viewController.view.frame.width
    let initialPreviewWidth = initialDetail.splitViewItems[1].viewController.view.frame.width
    try capture("01-grid")
    owner.select(library.entries[2].id)
    try await Task.sleep(for: .milliseconds(250))
    #expect(abs(initialDetail.splitViewItems[0].viewController.view.frame.width - initialBrowserWidth) < 2)
    #expect(abs(initialDetail.splitViewItems[1].viewController.view.frame.width - initialPreviewWidth) < 2)
    #expect(controllers.count == 1)
    try capture("02-preview")
    owner.activateSearch()
    try await Task.sleep(for: .milliseconds(100))
    #expect(owner.selectedEntry?.id == library.entries[2].id)
    try capture("09-search-with-note")
    owner.window.makeFirstResponder(owner.selected?.session.host.editor)
    try await Task.sleep(for: .milliseconds(100))
    #expect(searchItem.view == nil && searchItem.image != nil)

    let detail = try #require(split.splitViewItems[1].viewController.children.first as? NSSplitViewController)
    let dividerFrame = detail.view.convert(detail.view.bounds, to: nil)
    #expect(dividerFrame.maxY <= owner.window.contentLayoutRect.maxY + 0.5)
    let previewView = detail.splitViewItems[1].viewController.view
    let browserView = detail.splitViewItems[0].viewController.view
    split.splitView.setPosition(300, ofDividerAt: 0)
    split.view.layoutSubtreeIfNeeded()
    try await Task.sleep(for: .milliseconds(150))
    let contentView = split.splitViewItems[1].viewController.view
    let contentLeft = contentView.convert(contentView.bounds, to: split.splitView).minX
    #expect(abs(contentLeft - 300) < 2)
    #expect(sideView.frame.width > 250) // Native floating glass has its own outer inset.
    detail.splitView.setPosition(detail.splitView.bounds.width - 430 - detail.splitView.dividerThickness, ofDividerAt: 0)
    detail.view.layoutSubtreeIfNeeded()
    try await Task.sleep(for: .milliseconds(150))
    #expect(abs(previewView.frame.width - 430) < 2)
    #expect(browserView.frame.width >= 300)
    #expect(owner.selected?.session.inPreview == true) // Selecting the card already entered the editor.
    try await Task.sleep(for: .milliseconds(200))
    let session = try #require(owner.selected?.session)
    let editor = session.host.editor
    let slot = try #require(session.host.superview)
    let history = editor.undoManager
    editor.setSelectedRange(NSRange(location: 3, length: 2))
    let selection = editor.selectedRange()
    let document = owner.selected?.store.document
    // Change only this helper process's volatile defaults, sending the same KVO
    // update that AppStorage observes, without persisting user preferences.
    func setMaterial(_ mode: NoteAppearance) {
        UserDefaults.standard.willChangeValue(forKey: NoteAppearance.preferenceKey)
        UserDefaults.standard.setVolatileDomain([NoteAppearance.preferenceKey: mode.rawValue], forName: UserDefaults.argumentDomain)
        UserDefaults.standard.didChangeValue(forKey: NoteAppearance.preferenceKey)
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: UserDefaults.standard)
    }
    for mode in [NoteAppearance.translucent, .paper] {
        setMaterial(mode)
        try await Task.sleep(for: .milliseconds(250))
        #expect(session.libraryInk == mode.textColor)
        #expect(session.host.superview === slot && session.host.editor === editor)
        #expect(editor.undoManager === history && editor.selectedRange() == selection)
        #expect(owner.selected?.store.document == document)
        try capture(mode == .translucent ? "10-glass" : "11-paper-restored")
    }
    detail.splitView.setPosition(detail.splitView.bounds.width - 350 - detail.splitView.dividerThickness, ofDividerAt: 0)
    detail.view.layoutSubtreeIfNeeded()
    try await Task.sleep(for: .milliseconds(100))
    #expect(abs(previewView.frame.width - 350) < 2)
    #expect(session.host.superview === slot && session.host.editor === editor)
    #expect(editor.undoManager === history && editor.selectedRange() == selection)
    #expect(owner.selected?.store.document == document)
    try capture("06-resized")
    let rememberedWidth = previewView.frame.width
    owner.closePreview()
    try await Task.sleep(for: .milliseconds(100))
    #expect(!detail.splitViewItems[1].isCollapsed)
    #expect(abs(previewView.frame.width - rememberedWidth) < 2)
    owner.select(library.entries[2].id)
    try await Task.sleep(for: .milliseconds(150))
    #expect(abs(previewView.frame.width - rememberedWidth) < 2)
    #expect(owner.selected?.session.inPreview == true) // Selecting the card already entered the editor.
    try await Task.sleep(for: .milliseconds(150))
    let resizedSlot = try #require(session.host.superview)

    owner.grid = false
    try await Task.sleep(for: .milliseconds(150))
    try capture("03-list")
    owner.grid = true
    owner.window.setContentSize(NSSize(width: 800, height: 650))
    try await Task.sleep(for: .milliseconds(150))
    try capture("04-narrow")
    #expect(controllers.count == 1)
    #expect(split.splitViewItems[0].isCollapsed)
    #expect(!detail.splitViewItems[0].isCollapsed)
    #expect(!detail.splitViewItems[1].isCollapsed)
    #expect(session.host.superview === resizedSlot)
    #expect(editor.undoManager === history)
    owner.window.setContentSize(NSSize(width: 1240, height: 780))
    app.appearance = NSAppearance(named: .darkAqua)
    try await Task.sleep(for: .milliseconds(200))
    try capture("05-dark")
    #expect(!split.splitViewItems[0].isCollapsed)
    #expect(!detail.splitViewItems[0].isCollapsed)
    #expect(session.host.superview === resizedSlot)
    #expect(abs(previewView.frame.width - rememberedWidth) < 2)
    owner.sidebar = false
    #expect(split.splitViewItems[0].isCollapsed)
    owner.sidebar = true
    #expect(!split.splitViewItems[0].isCollapsed)
    // A live desktop note is directly editable too, without changing its shelf state.
    owner.select(library.entries[0].id)
    try await Task.sleep(for: .milliseconds(200))
    let live = try #require(owner.selected?.session)
    #expect(live.inPreview && !live.store.document.isShelved)
    #expect(live !== session && !session.inPreview)
    #expect(live.host.editor.string.contains("这周想完成的事"))
    let librarySlot = try #require(live.librarySlot)
    let desktopSlot = try #require(live.desktopSlot as? NoteEditingSlot)
    let liveEditor = live.host.editor
    let liveUndo = try #require(liveEditor.undoManager)
    liveUndo.beginUndoGrouping()
    liveEditor.setSelectedRange(NSRange(location: 0, length: 0))
    liveEditor.insertText("直接编辑 ", replacementRange: liveEditor.selectedRange())
    liveUndo.endUndoGrouping()
    #expect(live.store.document.content.plainText.hasPrefix("直接编辑 "))
    #expect(desktopSlot.claimEditor())
    #expect(!live.inPreview && live.host.superview === desktopSlot)
    #expect(liveEditor.undoManager === liveUndo)
    liveUndo.undo()
    #expect(!live.store.document.content.plainText.hasPrefix("直接编辑 "))
    #expect(librarySlot.claimEditor())
    #expect(live.inPreview && live.host.superview === librarySlot)
    #expect(!live.store.document.isShelved)
    owner.select(library.entries[2].id)
    try await Task.sleep(for: .milliseconds(200))
    #expect(owner.selected?.session === session && session.inPreview)
    #expect(!live.inPreview && live.host.superview === desktopSlot)
    #expect(session.host.editor.string.contains("收起来之后"))
    owner.navigate(.favorites)
    #expect(owner.results.count == 2)
    owner.navigate(.collection(cid))
    #expect(owner.results.count == 4)
    owner.navigate(.shelved)
    #expect(owner.results.count == 6)
    #expect(owner.window.alphaValue == 0)
    owner.navigate(.all)
    owner.activateSearch()
    try await Task.sleep(for: .milliseconds(100))
    let field = try #require(owner.window.toolbar?.items.compactMap { $0.view as? NSSearchField }.first)
    #expect(field.currentEditor() != nil)
    try capture("07-search-expanded")
    field.stringValue = "找回"
    owner.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
    #expect(owner.results.count == 1)
    field.stringValue = ".*"
    owner.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
    #expect(owner.results.isEmpty) // literal search, not regex
    field.stringValue = ""
    owner.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
    let fieldEditor = try #require(field.currentEditor() as? NSTextView)
    #expect(owner.control(field, textView: fieldEditor, doCommandBy: #selector(NSResponder.cancelOperation(_:))))
    try await Task.sleep(for: .milliseconds(100))
    #expect(searchItem.view == nil && searchItem.image != nil)
    try capture("08-search-collapsed")
    owner.multiple = true; owner.picked = [library.entries[0].id]
    owner.navigate(.shelved)
    #expect(!owner.multiple && owner.picked.isEmpty)

    owner.navigate(.all)
    owner.grid = true
    app.appearance = NSAppearance(named: .aqua)
    try await Task.sleep(for: .milliseconds(200))
    func findMarquee(_ view: NSView) -> ShelfMarqueeView? {
        if let found = view as? ShelfMarqueeView { return found }
        return view.subviews.compactMap(findMarquee).first
    }
    let marquee = try #require(findMarquee(owner.window.contentView!))
    let visible = marquee.itemFrames.filter { $0.value.intersects(marquee.bounds) }.sorted { $0.value.minY == $1.value.minY ? $0.value.minX < $1.value.minX : $0.value.minY < $1.value.minY }
    #expect(visible.count >= 2)
    let first = try #require(visible.first)
    let second = visible[1]
    let startPoint = NSPoint(x: 4, y: 4)
    let endPoint = NSPoint(x: second.value.maxX - 5, y: max(first.value.maxY, second.value.maxY) - 5)
    func pointer(_ type: NSEvent.EventType, _ point: NSPoint, _ flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(with: type, location: marquee.convert(point, to: nil), modifierFlags: flags,
            timestamp: 0, windowNumber: owner.window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
    }
    #expect(marquee.hitTest(marquee.convert(startPoint, to: marquee.superview)) === marquee)
    #expect(marquee.hitTest(marquee.convert(NSPoint(x: first.value.midX, y: first.value.midY), to: marquee.superview)) == nil)
    marquee.mouseDown(with: try pointer(.leftMouseDown, startPoint))
    marquee.mouseDragged(with: try pointer(.leftMouseDragged, endPoint))
    #expect(owner.marqueeActive)
    #expect(owner.picked.contains(first.key) && owner.picked.contains(second.key))
    try capture("12-marquee")
    // Layout may report several sets of frames in one render transaction.
    // It must not publish selection synchronously or repeat identical selections.
    var selectionPublications = 0
    let selectionObserver = owner.objectWillChange.sink { selectionPublications += 1 }
    let measuredFrames = marquee.itemFrames
    marquee.itemFrames = measuredFrames.mapValues { $0.offsetBy(dx: 0, dy: 10_000) }
    marquee.itemFrames = measuredFrames
    #expect(selectionPublications == 0)
    try await Task.sleep(for: .milliseconds(30))
    #expect(selectionPublications == 0)
    #expect(owner.picked.contains(first.key) && owner.picked.contains(second.key))
    // Queue another geometry pass, then release: stale work must not reopen
    // multi-selection or alter its final contents after mouse-up.
    marquee.itemFrames = measuredFrames.mapValues { $0.offsetBy(dx: 0, dy: 1) }
    marquee.mouseUp(with: try pointer(.leftMouseUp, endPoint))
    try await Task.sleep(for: .milliseconds(200))
    selectionObserver.cancel()
    #expect(owner.showsSelectionSummary && !owner.marqueeActive)
    #expect(owner.picked.contains(first.key) && owner.picked.contains(second.key))
    #expect(!detail.splitViewItems[1].isCollapsed)
    #expect(owner.selected == nil)
    try capture("13-multiple-inspector")
    let pickedBefore = owner.picked
    #expect(owner.beginMarquee())
    owner.applyMarquee([first.key], base: pickedBefore, modifiers: .command)
    owner.endMarquee()
    #expect(owner.picked == pickedBefore.symmetricDifference([first.key]))
    #expect(owner.beginMarquee())
    owner.applyMarquee([first.key], base: owner.picked, modifiers: .shift)
    owner.endMarquee()
    #expect(owner.picked == pickedBefore)
    owner.select(first.key)
    try await Task.sleep(for: .milliseconds(150))
    #expect(!owner.multiple && owner.picked.isEmpty)
    #expect(owner.selectedEntry?.id == first.key && owner.selected?.session.inPreview == true)

    owner.navigate(.all)
    owner.grid = false
    try await Task.sleep(for: .milliseconds(200))
    let listMarquee = try #require(findMarquee(owner.window.contentView!))
    #expect(listMarquee.itemFrames.count >= 2)
    // Find the native scrolling surface and ensure drag-to-edge advances it.
    owner.grid = true
    owner.window.setContentSize(NSSize(width: 1000, height: 500))
    try await Task.sleep(for: .milliseconds(200))
    let scrollMarquee = try #require(findMarquee(owner.window.contentView!))
    let initialFrames = scrollMarquee.itemFrames
    let initialTop = try #require(initialFrames.values.map(\.minY).min())
    func scrollPointer(_ type: NSEvent.EventType, _ point: NSPoint) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(with: type, location: scrollMarquee.convert(point, to: nil), modifierFlags: [],
            timestamp: 0, windowNumber: owner.window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
    }
    scrollMarquee.mouseDown(with: try scrollPointer(.leftMouseDown, NSPoint(x: 4, y: 4)))
    let edge = NSPoint(x: scrollMarquee.bounds.maxX - 30, y: scrollMarquee.bounds.maxY - 4)
    scrollMarquee.mouseDragged(with: try scrollPointer(.leftMouseDragged, edge))
    try await Task.sleep(for: .milliseconds(400))
    #expect((scrollMarquee.itemFrames.values.map(\.minY).min() ?? initialTop) < initialTop)
    scrollMarquee.mouseUp(with: try scrollPointer(.leftMouseUp, edge))

    // ⌘A shares the visible-result selection path, without stealing text selection.
    owner.navigate(.favorites)
    owner.window.makeFirstResponder(nil)
    #expect(owner.selectAllIfBrowsing())
    #expect(owner.picked == Set(owner.results.map(\.id)) && owner.picked.count == 2)
    #expect(owner.showsSelectionSummary)
    owner.navigate(.all)
    field.stringValue = "找回"
    owner.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
    #expect(owner.selectAllIfBrowsing())
    #expect(owner.picked.count == 1 && owner.picked == Set(owner.results.map(\.id)))
    field.stringValue = "no-matching-note"
    owner.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
    #expect(owner.selectAllIfBrowsing())
    #expect(owner.picked.isEmpty && !owner.multiple)
    field.stringValue = ""
    owner.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
    owner.activateSearch()
    try await Task.sleep(for: .milliseconds(100))
    #expect(owner.window.firstResponder is NSTextView)
    #expect(!owner.selectAllIfBrowsing() && owner.picked.isEmpty)
    owner.window.makeFirstResponder(nil)
    owner.select(first.key)
    try await Task.sleep(for: .milliseconds(150))
    let textSession = try #require(owner.selected?.session)
    owner.window.makeFirstResponder(textSession.host.editor)
    let textSelection = textSession.host.editor.selectedRange()
    #expect(!owner.selectAllIfBrowsing() && owner.picked.isEmpty)
    #expect(textSession.host.editor.selectedRange() == textSelection)
    #expect(owner.selectedEntry?.id == first.key && textSession.inPreview)

    // Calendar-day grouping is exclusive and respects local daylight-saving days.
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
    let now = calendar.date(from: DateComponents(year: 2026, month: 3, day: 9, hour: 12))!
    let buckets: [(Int, ShelfDateGroup)] = [(-1, .today), (0, .today), (1, .yesterday), (2, .week), (7, .week), (8, .month), (30, .month), (31, .earlier)]
    for (days, expected) in buckets {
        let date = calendar.date(byAdding: .day, value: -days, to: now)!
        #expect(ShelfDateGroup.containing(date, now: now, calendar: calendar) == expected)
    }
    owner.navigate(.all)
    owner.sort = "Recently Modified"
    let grouped = owner.sections(grouped: true)
    #expect(grouped.map(\.id) == ShelfDateGroup.allCases.map(\.rawValue))
    #expect(grouped.flatMap(\.items).map(\.id) == owner.results.map(\.id))
    #expect(grouped.allSatisfy { !$0.items.isEmpty })
    #expect(owner.sections(grouped: false).count == 1)
    owner.sort = "Oldest Modified"
    #expect(owner.sections(grouped: true).map(\.id) == ShelfDateGroup.allCases.reversed().map(\.rawValue))
    owner.sort = "Recently Created"
    #expect(owner.sections(grouped: true).count == 1)
    owner.sort = "Recently Modified"
    owner.window.setContentSize(NSSize(width: 1240, height: 780))
    let oldest = try #require(owner.results.last?.id)
    owner.select(oldest)
    try await Task.sleep(for: .milliseconds(150))
    let stableOrder = owner.results.map(\.id)
    let stableGroups = owner.sections(grouped: true).map { ($0.id, $0.items.map(\.id)) }
    let activeEditor = try #require(owner.selected?.session.host.editor)
    activeEditor.setSelectedRange(NSRange(location: (activeEditor.string as NSString).length, length: 0))
    activeEditor.insertText(" updated", replacementRange: NSRange(location: NSNotFound, length: 0))
    try await Task.sleep(for: .milliseconds(250))
    owner.rebuild()
    #expect(owner.results.map(\.id) == stableOrder)
    #expect(owner.sections(grouped: true).map(\.id) == stableGroups.map { $0.0 })
    #expect(owner.sections(grouped: true).map { $0.items.map(\.id) } == stableGroups.map { $0.1 })
    #expect(owner.beginMarquee())
    #expect(owner.results.map(\.id) == stableOrder)
    owner.endMarquee()
    #expect(owner.results.first?.id == oldest)
    #expect(owner.sections(grouped: true).first?.id == ShelfDateGroup.today.rawValue)
    owner.closePreview()
    try await Task.sleep(for: .milliseconds(150))
    func resetScroll(_ view: NSView) {
        if let scroll = view as? NSScrollView {
            scroll.contentView.scroll(to: .zero)
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        for child in view.subviews { resetScroll(child) }
    }
    resetScroll(browserView)
    try await Task.sleep(for: .milliseconds(100))
    try capture("14-date-groups-grid")
    owner.grid = false
    try await Task.sleep(for: .milliseconds(150))
    resetScroll(browserView)
    try await Task.sleep(for: .milliseconds(100))
    try capture("15-date-groups-list")

    // Render the exact shared palette in an invisible native window; do not
    // show a user-visible action panel or touch the real note library.
    owner.select(library.entries[0].id)
    try await Task.sleep(for: .milliseconds(150))
    let actionEntry = try #require(owner.selectedEntry)
    let actionSession = try #require(owner.selected?.session)
    let actionEditor = actionSession.host.editor
    let actionHistory = actionEditor.undoManager
    let actionSelection = actionEditor.selectedRange()
    #expect(owner.noteActionsState.actionsAnchor?.window === owner.window)
    let actionSections = owner.noteActionSections(actionEntry.id)
    #expect(actionSections.flatMap(\.items).contains { $0.id == "open" })
    #expect(actionSections.flatMap(\.items).contains { $0.id == "collection:" + cid.uuidString })
    var chosenCustom: String?
    var chosenDesktop: NoteAction?
    var openedColors = false
    let paletteWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 340, height: 380),
        styleMask: [.borderless], backing: .buffered, defer: false)
    paletteWindow.isReleasedWhenClosed = false
    paletteWindow.alphaValue = 0
    defer { paletteWindow.orderOut(nil); paletteWindow.close() }
    func palette(_ custom: [ActionPaletteSection]?) -> NSHostingView<NoteActionsView> {
        let host = NSHostingView(rootView: NoteActionsView(store: actionEntry.store, width: 340, height: 380,
            isEnabled: { _ in true }, perform: { chosenDesktop = $0 }, dismiss: {},
            openColors: { _ in openedColors = true }, customSections: custom,
            performCustom: { chosenCustom = $0 }))
        host.frame = NSRect(x: 0, y: 0, width: 340, height: 380)
        host.sizingOptions = []
        paletteWindow.contentView = EditorGlassSurface(content: host, cornerRadius: 15)
        paletteWindow.orderFrontRegardless()
        return host
    }
    func findSearch(_ view: NSView) -> NSSearchField? {
        if let field = view as? NSSearchField { return field }
        return view.subviews.compactMap(findSearch).first
    }
    func searchPalette(_ host: NSView, _ query: String) async throws -> (NSSearchField, NSTextView) {
        let field = try #require(findSearch(host))
        paletteWindow.makeFirstResponder(field)
        field.stringValue = query
        field.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: field))
        try await Task.sleep(for: .milliseconds(100))
        let editor = try #require(field.currentEditor() as? NSTextView)
        editor.setSelectedRange(NSRange(location: (query as NSString).length, length: 0))
        return (field, editor)
    }
    func capturePalette(_ name: String) throws {
        func findHost(_ view: NSView) -> NSView? {
            if view is NSHostingView<NoteActionsView> { return view }
            return view.subviews.compactMap(findHost).first
        }
        // Glass is compositor-owned; capture its actual hosted content for layout QA.
        let view = try #require(paletteWindow.contentView.flatMap(findHost))
        view.layoutSubtreeIfNeeded()
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let output = URL(fileURLWithPath: ProcessInfo.processInfo.environment["FOLDPIN_CHECK_OUTPUT"]!)
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent(name + ".png"))
    }
    let customHost = palette(actionSections)
    try await Task.sleep(for: .milliseconds(150))
    try capturePalette("16-library-actions")
    let favoriteTitle = try #require(actionSections.flatMap(\.items).first { $0.id == "favorite" }?.title)
    let (customField, customEditor) = try await searchPalette(customHost, favoriteTitle)
    #expect(customField.delegate?.control?(customField, textView: customEditor, doCommandBy: #selector(NSResponder.insertNewline(_:))) == true)
    #expect(chosenCustom == "favorite")
    #expect(actionSession.host.editor === actionEditor && actionEditor.undoManager === actionHistory)
    #expect(actionEditor.selectedRange() == actionSelection && actionSession.inPreview)
    let desktopHost = palette(nil)
    try await Task.sleep(for: .milliseconds(150))
    try capturePalette("17-desktop-actions")
    let (desktopField, desktopEditor) = try await searchPalette(desktopHost, "yellow")
    #expect(desktopField.delegate?.control?(desktopField, textView: desktopEditor, doCommandBy: #selector(NSResponder.insertNewline(_:))) == true)
    #expect(chosenDesktop == .yellow)
    let (colorField, colorEditor) = try await searchPalette(desktopHost, "color")
    #expect(colorField.delegate?.control?(colorField, textView: colorEditor, doCommandBy: #selector(NSResponder.moveRight(_:))) == true)
    #expect(openedColors)
    // The callback revalidates the target UUID after its deferred dispatch.
    let oldFavorite = actionEntry.store.document.isFavorite
    owner.select(library.entries[1].id)
    owner.performNoteMenuAction("favorite", noteID: actionEntry.id)
    #expect(actionEntry.store.document.isFavorite == oldFavorite)
    owner.select(actionEntry.id)
    owner.performNoteMenuAction("favorite", noteID: actionEntry.id)
    #expect(actionEntry.store.document.isFavorite != oldFavorite)
    owner.performNoteMenuAction("favorite", noteID: actionEntry.id)
    #expect(actionEntry.store.document.isFavorite == oldFavorite)
    #expect(paletteWindow.alphaValue == 0 && owner.window.alphaValue == 0)

    // Modified clicks select synchronously on mouse-down, without waiting for
    // mouse-up or the system double-click interval. Test both presentation modes.
    owner.navigate(.all)
    for grid in [true, false] {
        owner.grid = grid
        try await Task.sleep(for: .milliseconds(150))
        resetScroll(browserView)
        try await Task.sleep(for: .milliseconds(100))
        let input = try #require(findMarquee(browserView))
        let visibleItems = owner.results.filter { item in
            guard let rect = input.itemFrames[item.id] else { return false }
            return input.bounds.contains(NSPoint(x: rect.midX, y: rect.midY))
        }
        let a = try #require(visibleItems.first)
        let b = try #require(visibleItems.dropFirst().first)
        func clickEvent(_ item: ShelfSummary, _ type: NSEvent.EventType, _ flags: NSEvent.ModifierFlags) throws -> NSEvent {
            let rect = try #require(input.itemFrames[item.id])
            return try #require(NSEvent.mouseEvent(with: type,
                location: input.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil), modifierFlags: flags,
                timestamp: 0, windowNumber: owner.window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        }
        let down = try clickEvent(a, .leftMouseDown, [])
        let rect = try #require(input.itemFrames[a.id])
        let point = NSPoint(x: rect.midX, y: rect.midY)
        #expect(input.capturesItemPress(at: point, event: down))
        #expect(!input.capturesItemPress(at: point, event: try clickEvent(a, .leftMouseDown, .control)))
        #expect(!input.capturesItemPress(at: point, event: try clickEvent(a, .rightMouseDown, [])))
        if let control = input.controlFrames.first {
            #expect(!input.capturesItemPress(at: NSPoint(x: control.midX, y: control.midY), event: down))
        }
        let before = CFAbsoluteTimeGetCurrent()
        input.mouseDown(with: down)
        let duration = (CFAbsoluteTimeGetCurrent() - before) * 1000
        print("Native single selection (grid=\(grid)): \(duration) ms; double-click interval \(NSEvent.doubleClickInterval * 1000) ms")
        #expect(owner.selectedEntry?.id == a.id && !owner.multiple)
        input.mouseUp(with: try clickEvent(a, .leftMouseUp, []))
        #expect(owner.selectedEntry?.id == a.id)
        try await Task.sleep(for: .milliseconds(150))
        #expect(owner.selected?.session.inPreview == true)
        owner.navigate(.all)
        input.mouseDown(with: try clickEvent(a, .leftMouseDown, .command))
        #expect(owner.picked == [a.id])
        input.mouseUp(with: try clickEvent(a, .leftMouseUp, []))
        #expect(owner.picked == [a.id])
        input.mouseDown(with: try clickEvent(b, .leftMouseDown, .shift))
        #expect(owner.picked.contains(a.id) && owner.picked.contains(b.id))
        input.mouseUp(with: try clickEvent(b, .leftMouseUp, []))
        input.mouseDown(with: try clickEvent(a, .leftMouseDown, .command))
        #expect(!owner.picked.contains(a.id) && owner.picked.contains(b.id))
        input.mouseUp(with: try clickEvent(a, .leftMouseUp, []))
        #expect(owner.selected == nil && !owner.marqueeActive)
        owner.navigate(.all)
    }

    // Finder-style file URLs use the real asynchronous import path in the
    // shared library editor, with the same store/session as the desktop paper.
    owner.navigate(.all)
    owner.select(library.entries[0].id)
    try await Task.sleep(for: .milliseconds(150))
    let fileSession = try #require(owner.selected?.session)
    let fileEditor = fileSession.host.editor
    let fileHistory = fileEditor.undoManager
    let sampleFile = directory.appendingPathComponent("meeting-notes.txt")
    let sampleData = Data("Sample attachment document".utf8)
    try sampleData.write(to: sampleFile)
    let filesBoard = NSPasteboard(name: .init(UUID().uuidString))
    defer { filesBoard.releaseGlobally() }
    filesBoard.writeObjects([sampleFile as NSURL])
    fileEditor.setSelectedRange(NSRange(location: 0, length: 0))
    #expect(fileEditor.importAttachments(from: filesBoard))
    for _ in 0..<80 {
        if fileEditor.content.blocks.contains(where: { $0.attachment != nil }) { break }
        try await Task.sleep(for: .milliseconds(50))
    }
    let importedFile = try #require(fileEditor.content.blocks.compactMap(\.attachment).first)
    #expect(fileSession.host.editor === fileEditor && fileEditor.undoManager === fileHistory)
    #expect(fileSession.store.document.content.blocks.contains { $0.attachment == importedFile })
    #expect(fileSession.store.flush())
    #expect(try fileSession.store.file.load().content.blocks.contains { $0.attachment == importedFile })
    try FileManager.default.removeItem(at: sampleFile)
    #expect(try Data(contentsOf: fileSession.store.file.attachmentURL(importedFile)) == sampleData)
    owner.rebuild()
    #expect(owner.summaries.first { $0.id == fileSession.store.document.id }?.types.contains("Attachments") == true)
    try await Task.sleep(for: .milliseconds(150))
    try capture("18-file-attachment")

    let exportController = try #require(owner.selected)
    let exported = try #require(exportController.exportSource())
    #expect(exported.document == fileSession.store.document)
    #expect(NoteAction.exportNote.isPaperAction && NoteAction.exportNote.key.isEmpty)
    #expect(owner.noteActionSections(exported.document.id).flatMap(\.items).contains { $0.id == "export" && $0.enabled })
    let singleExport = try owner.exportSources(ids: [exported.document.id])
    #expect(singleExport.count == 1 && singleExport[0].document == exported.document)
    let retainedSelection = owner.picked
    let batchExport = try owner.exportSources(ids: Set(library.entries.prefix(3).map(\.id)))
    #expect(batchExport.count == 3 && owner.picked == retainedSelection)
    #expect(fileSession.inPreview && fileSession.host.editor === fileEditor && fileEditor.undoManager === fileHistory)
    #expect(throws: NoteExportError.self) { try owner.exportSources(ids: [UUID()]) }

    owner.navigate(.all)
    let deleteA = try #require(library.createNote())
    let deleteB = try #require(library.createNote())
    let deleteC = try #require(library.createNote())
    deleteA.store.edit("Permanent deletion A")
    deleteB.store.edit("Permanent deletion B")
    deleteC.store.edit("Permanent deletion C")
    let deadController = PaperWindowController(entry: deleteA)
    controllers[deleteA.id] = deadController
    #expect(library.deleteNote(deleteA.id) && library.deleteNote(deleteB.id) && library.deleteNote(deleteC.id))
    owner.navigate(.deleted); owner.rebuild()
    let allDeleted = Set(library.deletedEntries.map(\.id))
    #expect(owner.permanentDeletionTargets == allDeleted)
    field.stringValue = "nonmatching filter"
    owner.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
    #expect(owner.results.isEmpty && owner.permanentDeletionTargets == allDeleted)
    field.stringValue = ""
    owner.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field)); owner.rebuild()
    try await Task.sleep(for: .milliseconds(150)); try capture("19-delete-all")
    owner.select(deleteA.id)
    #expect(owner.permanentDeletionTargets == [deleteA.id])
    try await Task.sleep(for: .milliseconds(150)); try capture("20-delete-one")
    owner.navigate(.deleted); owner.select(deleteA.id, modifiers: .command); owner.select(deleteB.id, modifiers: .command)
    #expect(owner.permanentDeletionTargets == [deleteA.id, deleteB.id])
    owner.permanentlyDelete(ids: [deleteA.id, deleteB.id])
    #expect(!FileManager.default.fileExists(atPath: deleteA.store.file.url.path))
    #expect(controllers[deleteA.id] == nil && deadController.paper.contentView == nil)
    #expect(library.deletedEntries.contains { $0.id == deleteC.id })
    #expect(!owner.picked.contains(deleteA.id) && !owner.picked.contains(deleteB.id))
    owner.selectAllNotes()
    #expect(owner.permanentDeletionTargets == Set(library.deletedEntries.map(\.id)))
    let restored = try #require(library.restoreNote(deleteC.id, toShelf: true))
    owner.permanentlyDelete(ids: [restored.id])
    #expect(library.entry(restored.id) != nil)
    owner.navigate(.deleted)
    owner.permanentlyDelete(ids: owner.permanentDeletionTargets)
    #expect(library.deletedEntries.isEmpty && owner.permanentDeletionTargets.isEmpty)

}


/// Dirty stores make a synchronous mount/flush observable even without the
/// Xcode runtime-issue debugger. All files and windows are synthetic.
@Test @MainActor func libraryWindowUpdateTransactions() async throws {
    let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["FOLDPIN_CHECK_DATA"]!)
        .appendingPathComponent(UUID().uuidString)
    let library = NoteLibrary(directory: directory)
    let entry = try #require(library.entries.first)
    let session = NoteEditingSession(store: entry.store)
    let desktop = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
    session.desktopSlot = desktop
    session.mount(in: desktop)
    let history = session.host.editor.undoManager
    entry.store.setPinned(!entry.store.document.isPinned)
    #expect(entry.store.isDirty)
    var publications = 0
    let observer = entry.store.objectWillChange.sink { publications += 1 }
    let window = NSWindow(contentRect: desktop.frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.isRestorable = false
    defer { observer.cancel(); window.contentView = nil; window.close() }
    let host = NSHostingView(rootView: ShelfEditorSlot(session: session, store: entry.store, appearance: .paper))
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    #expect(publications == 0)
    #expect(entry.store.isDirty && !session.inPreview)
    try await Task.sleep(for: .milliseconds(100))
    #expect(session.inPreview && !entry.store.isDirty)
    #expect(session.host.editor.undoManager === history)
    #expect(session.endPreview())
    window.contentView = nil
    // A slot removed before the deferred claim runs must not take the editor.
    let obsolete = NSHostingView(rootView: ShelfEditorSlot(session: session, store: entry.store, appearance: .paper))
    window.contentView = obsolete
    obsolete.layoutSubtreeIfNeeded()
    window.contentView = nil
    try await Task.sleep(for: .milliseconds(100))
    #expect(!session.inPreview && session.host.superview === desktop)
}

@Test @MainActor func libraryWindowStorageRetainsEditorAndUndo() throws {
    let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["FOLDPIN_CHECK_DATA"]!).appendingPathComponent(UUID().uuidString)
    let library = NoteLibrary(directory: root.appendingPathComponent("source"), localDirectory: root.appendingPathComponent("local"))
    let entry = try #require(library.entries.first)
    entry.store.edit("Original"); #expect(entry.store.flush())
    let session = NoteEditingSession(store: entry.store), editor = session.host.editor
    let history = try #require(editor.undoManager)
    history.groupsByEvent = false
    history.beginUndoGrouping()
    editor.insertText(" + local", replacementRange: NSRange(location: editor.string.utf16.count, length: 0))
    history.endUndoGrouping()
    #expect(session.prepareToLeave())
    let before = editor.content, selection = editor.selectedRanges
    let prepared = try LibraryRelocation.copy(source: library.directory, destination: root.appendingPathComponent("shared"), journalURL: root.appendingPathComponent("journal"))
    for note in prepared.desktops { try LibraryDisk.desktop(note, at: LibraryPath(prepared.root, manifest: prepared.manifest, localDirectory: root.appendingPathComponent("local"))) }
    library.relocate(to: prepared.root, manifest: prepared.manifest, snapshot: prepared.snapshot)
    session.synchronizeContentFromStore()
    #expect(session.host.editor === editor && editor.undoManager === history)
    #expect(editor.selectedRanges == selection && editor.content == before)
    let remote = NoteLibrary(directory: prepared.root, manifest: prepared.manifest, snapshot: prepared.snapshot, localDirectory: root.appendingPathComponent("remote"))
    let remoteStore = try #require(remote.entries.first?.store)
    remoteStore.edit("Remote change"); #expect(remoteStore.flush())
    library.apply(try LibraryDisk.snapshot(prepared.root))
    history.beginUndoGrouping()
    session.synchronizeContentFromStore()
    history.endUndoGrouping()
    #expect(editor.string == "Remote change" && !entry.store.isDirty)
    #expect(editor.undoManager === history)
    history.undo()
    #expect(editor.content == before)
    history.undo()
    #expect(editor.string == "Original")
    #expect(entry.store.flush())
    #expect(try LibraryDisk.snapshot(prepared.root).notes.count == 1)
}

@Test @MainActor func libraryWindowStorageSettingsAndDirectoryLock() async throws {
    let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["FOLDPIN_CHECK_DATA"]!).appendingPathComponent(UUID().uuidString)
    let controller = LibraryLocationController(privateDirectory: root.appendingPathComponent("state"), defaultDirectory: root.appendingPathComponent("library"))
    #expect(controller.library.canCreate)
    #expect(throws: LibraryStorageError.self) {
        _ = try LibraryFolderAccess(url: controller.library.directory, lockDirectory: root.appendingPathComponent("state/locks"))
    }
    let host = NSHostingView(rootView: LibraryStorageSettingsView(storage: controller))
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 608, height: 508), styleMask: [.titled, .closable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.isRestorable = false
    defer { window.contentView = nil; window.close() }
    window.contentView = host; host.layoutSubtreeIfNeeded()
    try await Task.sleep(for: .milliseconds(150))
    host.layoutSubtreeIfNeeded()
    let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
    host.cacheDisplay(in: host.bounds, to: bitmap)
    let output = URL(fileURLWithPath: ProcessInfo.processInfo.environment["FOLDPIN_CHECK_OUTPUT"]!).appendingPathComponent("storage-settings.png")
    try #require(bitmap.representation(using: .png, properties: [:])).write(to: output)
    #expect(!controller.isBusy && controller.library.entries.count == 1)
}

@Test @MainActor func libraryWindowStorageBookmarkOpenAndCachedReturn() async throws {
    let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["FOLDPIN_CHECK_DATA"]!).appendingPathComponent(UUID().uuidString)
    let controller = LibraryLocationController(privateDirectory: root.appendingPathComponent("state"), defaultDirectory: root.appendingPathComponent("legacy"))
    let legacy = controller.library
    let first = try LibraryRelocation.copy(source: legacy.directory, destination: root.appendingPathComponent("first"), journalURL: root.appendingPathComponent("journal-first"))
    let second = try LibraryRelocation.copy(source: legacy.directory, destination: root.appendingPathComponent("second"), journalURL: root.appendingPathComponent("journal-second"))
    func open(_ url: URL) async throws {
        controller.open(url)
        for _ in 0..<100 where controller.isBusy { try await Task.sleep(for: .milliseconds(20)) }
        #expect(!controller.isBusy)
        #expect(controller.failure == nil)
        #expect(controller.library.directory.resolvingSymlinksInPath().path == url.resolvingSymlinksInPath().path)
    }
    try await open(first.root)
    let firstLibrary = controller.library
    let store = try #require(firstLibrary.entries.first?.store)
    store.edit("Saved on first library"); #expect(store.flush())
    try await open(second.root)
    #expect(controller.library !== firstLibrary)
    #expect(firstLibrary.path.writable == false)
    try await open(first.root)
    #expect(controller.library === firstLibrary)
    #expect(controller.library.entries.first?.store === store)
    #expect(store.document.text == "Saved on first library" && firstLibrary.path.writable)
    #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("state/location.json").path))
}

@Test @MainActor func libraryWindowStorageThousandNoteMigration() async throws {
    let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["FOLDPIN_CHECK_DATA"]!).appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("source")
    try FileManager.default.createDirectory(at: source.appendingPathComponent("notes"), withIntermediateDirectories: true)
    let attachment = NoteAttachment(name: "sample.bin", byteCount: 64 * 1024 * 1024)
    let asset = attachment.url(in: source.appendingPathComponent("assets/files"))
    try FileManager.default.createDirectory(at: asset.deletingLastPathComponent(), withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: asset.path, contents: nil)
    let output = try FileHandle(forWritingTo: asset)
    for _ in 0..<64 { try output.write(contentsOf: Data(repeating: 42, count: 1024 * 1024)) }
    try output.close()
    for index in 0..<1000 {
        var note = NoteDocument()
        note.content = NoteContent(blocks: [NoteBlock(kind: index % 2 == 0 ? .paragraph : .code, text: "Synthetic note \(index)"), NoteBlock(kind: .file, attachment: attachment)])
        try LibraryDisk.encode(note).write(to: source.appendingPathComponent("notes/" + note.id.uuidString + ".json"))
    }
    let started = Date()
    let worker = Task.detached { try LibraryRelocation.copy(source: source, destination: root.appendingPathComponent("target"), journalURL: root.appendingPathComponent("journal")) }
    var mainQueueResponded = false
    DispatchQueue.main.async { mainQueueResponded = true }
    let prepared = try await worker.value
    #expect(mainQueueResponded && prepared.snapshot.notes.count == 1000)
    #expect(try LibraryRelocation.digest(asset).1 == LibraryRelocation.digest(attachment.url(in: prepared.root.appendingPathComponent("assets/files"))).1)
    print("Library migration: 1,000 text/code notes + one shared 64 MiB attachment, \(Date().timeIntervalSince(started)) s")
}


@Test @MainActor func libraryWindowStorageRetriesAfterDirectoryLockIsReleased() throws {
    let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["FOLDPIN_CHECK_DATA"]!).appendingPathComponent(UUID().uuidString)
    let state = root.appendingPathComponent("state"), directory = root.appendingPathComponent("library")
    var first: LibraryLocationController? = LibraryLocationController(privateDirectory: state, defaultDirectory: directory)
    #expect(first?.library.canCreate == true)
    let second = LibraryLocationController(privateDirectory: state, defaultDirectory: directory)
    #expect(second.library.canCreate == false && second.failure != nil)
    first = nil
    second.retry()
    #expect(second.library.canCreate && second.failure == nil)
}

@Test @MainActor func libraryWindowDefaultLocationUpgradesWithoutChoosingFolderAndReusesIt() async throws {
    let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["FOLDPIN_CHECK_DATA"]!).appendingPathComponent(UUID().uuidString)
    let original = root.appendingPathComponent("default")
    let controller = LibraryLocationController(privateDirectory: root.appendingPathComponent("state"), defaultDirectory: original)
    let originalStore = try #require(controller.library.entries.first?.store)
    originalStore.edit("Contents of original default library"); #expect(originalStore.flush())
    let before = try LibraryRelocation.inventory(original)
    let custom = try LibraryRelocation.copy(source: original, destination: root.appendingPathComponent("custom"), journalURL: root.appendingPathComponent("custom-journal"))
    func waitForSwitch() async throws {
        for _ in 0..<100 where controller.isBusy { try await Task.sleep(for: .milliseconds(20)) }
        #expect(!controller.isBusy && controller.failure == nil)
    }
    controller.open(custom.root); try await waitForSwitch()
    let customStore = try #require(controller.library.entries.first?.store)
    customStore.edit("Current custom library must not be merged"); #expect(customStore.flush())
    // Calling this real default action would block the check if it opened a
    // modal upgrade dialog or a folder picker.
    controller.openDefaultLibrary(); try await waitForSwitch()
    #expect(controller.library.directory.path == original.appendingPathExtension("library").path)
    let defaultLibrary = controller.library
    let defaultStore = try #require(defaultLibrary.entries.first?.store)
    #expect(defaultStore.document.text == "Contents of original default library")
    #expect(try LibraryRelocation.inventory(original) == before)
    defaultStore.edit("New edits in default library"); #expect(defaultStore.flush())
    controller.open(custom.root); try await waitForSwitch()
    #expect(controller.library.entries.first?.store.document.text == "Current custom library must not be merged")
    controller.openDefaultLibrary(); try await waitForSwitch()
    #expect(controller.library === defaultLibrary && controller.library.entries.first?.store === defaultStore)
    #expect(defaultStore.document.text == "New edits in default library")
    controller.openDefaultLibrary()
    #expect(!controller.isBusy && controller.library === defaultLibrary)
    #expect(controller.status == "You are already using the default library.")
}
