import AppKit
import Testing
@testable import FoldpinCore

@MainActor private func menuEntries(bundle: Bundle = .main) -> [SlashCommandMenu.Entry] {
    let keys = ["Text", "Heading 1", "Heading 2", "Heading 3", "Heading 4", "Bullet List", "Numbered List", "To-do", "Quote", "Divider", "Table", "Code Block", "Image"]
    return zip(NoteBlockKind.allCases, keys).map {
        SlashCommandMenu.Entry(kind: $0.0, title: bundle.localizedString(forKey: $0.1, value: nil, table: nil))
    }
}

@Test @MainActor func slashPickerKeepsKeyboardSelectionScrollAndCloseAction() throws {
    let menu = SlashCommandMenu(blockID: UUID(), entries: menuEntries())
    var choice: NoteBlockKind?
    var dismissed = false
    menu.onChoose = { choice = $0 }
    menu.onDismiss = { dismissed = true }
    let view = menu.makeContentView(maximumHeight: 220)
    view.layoutSubtreeIfNeeded()
    #expect(view.frame.height == 220)
    #expect(view.rows.count == NoteBlockKind.allCases.count)
    #expect(view.rows.allSatisfy { !$0.acceptsFirstResponder && !$0.needsPanelToBecomeKey })
    menu.moveSelection(-1)
    #expect(menu.selectedIndex == menu.entries.count - 1)
    let last = try #require(view.rows.last)
    #expect(last.showsSelection && last.showsKeyboardFocus)
    #expect(view.scrollView.contentView.bounds.minY > 0)
    #expect(view.closeButton.frame.maxY <= view.bounds.maxY)
    menu.chooseSelected()
    #expect(choice == .image)
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
            #expect(view.rows.count == 13)
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
