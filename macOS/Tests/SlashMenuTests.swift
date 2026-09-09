import AppKit
import Testing
@testable import FoldpinCore

@MainActor private func menuEntries(bundle: Bundle = .main) -> [SlashCommandMenu.Entry] {
    let keys = ["Text", "Heading 1", "Heading 2", "Heading 3", "Heading 4", "Bullet List", "Numbered List", "To-do", "Quote", "Divider", "Table", "Code Block", "Image", "Record Audio"]
    var entries = zip(NoteBlockKind.allCases, keys).map {
        SlashCommandMenu.Entry(kind: $0.0, title: bundle.localizedString(forKey: $0.1, value: nil, table: nil))
    }
    entries.append(.init(kind: .audio, title: "Import Audio…", importsAudio: true))
    return entries
}

@Test @MainActor func slashPickerKeepsKeyboardSelectionScrollAndCloseAction() throws {
    let menu = SlashCommandMenu(blockID: UUID(), entries: menuEntries())
    var choice: NoteBlockKind?
    var dismissed = false
    menu.onChoose = { choice = $0 }
    var imported = false
    menu.onImportAudio = { imported = true }
    menu.onDismiss = { dismissed = true }
    let view = menu.makeContentView(maximumHeight: 220)
    view.layoutSubtreeIfNeeded()
    #expect(view.frame.height == 220)
    #expect(view.rows.count == menu.entries.count)
    #expect(view.rows.allSatisfy { !$0.acceptsFirstResponder && !$0.needsPanelToBecomeKey })
    menu.moveSelection(-1)
    #expect(menu.selectedIndex == menu.entries.count - 1)
    let last = try #require(view.rows.last)
    #expect(last.showsSelection && last.showsKeyboardFocus)
    #expect(view.scrollView.contentView.bounds.minY > 0)
    #expect(view.closeButton.frame.maxY <= view.bounds.maxY)
    menu.chooseSelected()
    #expect(imported && choice == nil)
    menu.moveSelection(1)
    #expect(menu.selectedIndex == 0 && view.rows[0].showsKeyboardFocus)
    view.rows[1].performClick(nil)
    #expect(choice == .heading)
    view.closeButton.performClick(nil)
    #expect(dismissed)
}

@Test @MainActor func slashPickerHintsMatchWorkingMarkdownRules() {
    for entry in menuEntries() {
        let hint = entry.inputHint(bundle: .main)
        if hint.isEmpty { continue }
        #expect(!hint.contains("Space") && !hint.contains("空格") && !hint.contains("+"))
        #expect(MarkdownBlockShortcut.match(prefix: hint, trigger: .space)?.kind == entry.kind)
    }
    #expect(MarkdownBlockShortcut.match(prefix: ">", trigger: .space)?.kind == .quote)
    #expect(MarkdownBlockShortcut.match(prefix: "\"", trigger: .space)?.kind == .quote)
}

@Test @MainActor func slashPickerScrollingUnderStationaryPointerKeepsArrowSequence() throws {
    let pointer = NSPoint(x: 640, y: 400)
    let menu = SlashCommandMenu(blockID: UUID(), entries: menuEntries(), pointerLocation: { pointer })
    let view = menu.makeContentView(maximumHeight: 180)
    view.layoutSubtreeIfNeeded()
    let entered = try #require(NSEvent.enterExitEvent(with: .mouseEntered, location: .zero, modifierFlags: [],
        timestamp: 1, windowNumber: 0, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil))
    let moved = try #require(NSEvent.mouseEvent(with: .mouseMoved, location: .zero, modifierFlags: [],
        timestamp: 1, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 0, pressure: 0))
    // Repeat through both groups and the wrap boundary with a short viewport.
    // Replay entry and delayed movement notifications after every scroll.
    for step in 1...(menu.entries.count * 2) {
        menu.moveSelection(1)
        let expected = step % menu.entries.count
        let offset = view.scrollView.contentView.bounds.origin
        let otherRow = view.rows[(expected + menu.entries.count - 2) % menu.entries.count]
        otherRow.mouseEntered(with: entered)
        otherRow.mouseMoved(with: moved)
        #expect(menu.selectedIndex == expected)
        #expect(view.rows[expected].showsSelection && view.rows[expected].showsKeyboardFocus)
        #expect(view.scrollView.contentView.bounds.origin == offset)
    }
    menu.moveSelection(-1)
    #expect(menu.selectedIndex == menu.entries.count - 1)
    #expect(view.scrollView.contentView.bounds.minY > 0)
    var chosen: NoteBlockKind?
    menu.onChoose = { chosen = $0 }
    var imported = false
    menu.onImportAudio = { imported = true }
    menu.chooseSelected()
    #expect(imported && chosen == nil)
}

@Test @MainActor func slashPickerRealPointerMotionAndClickStillTakeOver() throws {
    var pointer = NSPoint(x: 640, y: 400)
    let menu = SlashCommandMenu(blockID: UUID(), entries: menuEntries(), pointerLocation: { pointer })
    let view = menu.makeContentView(maximumHeight: 220)
    let moved = try #require(NSEvent.mouseEvent(with: .mouseMoved, location: .zero, modifierFlags: [],
        timestamp: 1, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 0, pressure: 0))
    menu.moveSelection(7)
    pointer.x += 4
    view.rows[5].mouseMoved(with: moved)
    #expect(menu.selectedIndex == 5 && view.rows[5].showsSelection && !view.rows[5].showsKeyboardFocus)
    menu.moveSelection(1)
    view.rows[3].mouseMoved(with: moved)
    #expect(menu.selectedIndex == 6 && view.rows[6].showsKeyboardFocus)
    // Moving within a row works without requiring an exit/re-entry first.
    pointer.y += 2
    view.rows[3].mouseMoved(with: moved)
    #expect(menu.selectedIndex == 3 && !view.rows[3].showsKeyboardFocus)
    var chosen: NoteBlockKind?
    menu.onChoose = { chosen = $0 }
    view.rows[4].performClick(nil)
    #expect(chosen == .heading4)
}

@Test @MainActor func slashPickerOffscreenAppearanceAndLanguageLayouts() throws {
    for locale in ["en", "zh-Hans"] {
        let languageRoot = ProcessInfo.processInfo.environment["FOLDPIN_MENU_LOCALE_ROOT"]
        let bundle = languageRoot.flatMap { Bundle(path: $0 + "/" + locale + ".lproj") } ?? .main
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let menu = SlashCommandMenu(blockID: UUID(), entries: menuEntries(bundle: bundle), bundle: bundle)
            let view = menu.makeContentView(maximumHeight: 440)
            view.appearance = NSAppearance(named: name)
            menu.moveSelection(1)
            view.layoutSubtreeIfNeeded()
            #expect(view.rows.count == menu.entries.count)
            for row in view.rows {
                let title = NSAttributedString(string: row.title, attributes: [.font: NSFont.systemFont(ofSize: 14)]).size().width
                let hint = NSAttributedString(string: row.shortcutHint, attributes: [.font: NSFont.systemFont(ofSize: 11)]).size().width
                #expect(title + hint + 66 < row.bounds.width)
            }
            if let folder = ProcessInfo.processInfo.environment["FOLDPIN_MENU_PREVIEW_DIR"] {
                let directory = URL(fileURLWithPath: folder)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                view.cacheDisplay(in: view.bounds, to: bitmap)
                try #require(bitmap.representation(using: .png, properties: [:]))
                    .write(to: directory.appendingPathComponent("slash-menu-\(locale)-\(name.rawValue).png"))
            }
        }
    }
}
