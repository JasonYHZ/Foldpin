import AppKit
import SwiftUI
import Testing
import ServiceManagement
@testable import FoldpinCore

/// Layout and route checks use an empty temporary library and never enable MCP or login items.
@Test @MainActor func settingsNativeLayoutAndNavigation() async throws {
    try await checkSettingsNativeLayout(categories: SettingsCategory.allCases)
}

@Test @MainActor func settingsShortcutScopeBelowToolbarAndSwitchesBothWays() async throws {
    try await checkSettingsNativeLayout(categories: [.shortcuts], checksNavigationChrome: false)
}

@MainActor private func checkSettingsNativeLayout(categories: [SettingsCategory], checksNavigationChrome: Bool = true) async throws {
    let app = NSApplication.shared
    app.setActivationPolicy(.prohibited)
    UserDefaults.standard.removePersistentDomain(forName: "Foldpin.Library.Check")
    UserDefaults.standard.removePersistentDomain(forName: "Foldpin.Settings.Check.Preferences")
    defer {
        UserDefaults.standard.removePersistentDomain(forName: "Foldpin.Library.Check")
        UserDefaults.standard.removePersistentDomain(forName: "Foldpin.Settings.Check.Preferences")
    }
    if let icon = NSImage(contentsOfFile: "/private/tmp/Foldpin-DerivedData/Build/Products/Debug/Foldpin.app/Contents/Resources/AppIcon.icns") {
        app.applicationIconImage = icon
    }
    let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["FOLDPIN_CHECK_DATA"]!).appendingPathComponent(UUID().uuidString)
    let output = URL(fileURLWithPath: ProcessInfo.processInfo.environment["FOLDPIN_CHECK_OUTPUT"]!)
    let storage = LibraryLocationController(privateDirectory: root.appendingPathComponent("local"), defaultDirectory: root.appendingPathComponent("library"))
    let suite = "Foldpin.Settings.Check." + UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let service = FoldpinCommandService(library: { storage.library }, journal: MCPJournal(directory: root.appendingPathComponent("receipts")))
    let server = MCPServer(commands: service, defaults: defaults)
    let login = LoginItemSettings(readStatus: { .requiresApproval }, register: { Issue.record("Must not register login items") }, unregister: { Issue.record("Must not unregister login items") }, installed: { true })
    let originalLibrary = storage.library
    let languages: [(String, AppLanguage)] = [("zh", .simplifiedChinese), ("en", .english)]
    for (code, language) in languages {
        LanguageSettings.shared.select(language)
        for dark in [false, true] {
            app.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            for category in categories {
                ShortcutSettings.shared.showShortcuts = false
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 680), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                let view = NSHostingView(rootView: FoldpinSettingsView(mcp: server, storage: storage, login: login, help: {}, feedback: {}, locate: { _ in }, selectedCategory: category))
                window.contentView = view
                for size in [NSSize(width: 900, height: 680), NSSize(width: 780, height: 560)] {
                    window.setContentSize(size)
                    for _ in 0..<5 { try await Task.sleep(for: .milliseconds(20)); view.layoutSubtreeIfNeeded() }
                    #expect(LanguageSettings.shared.selection == language)
                    #expect(view.bounds.width == size.width)
                    // Full-size content includes the system titlebar safe area.
                    let minimumHeight = 560 + view.safeAreaInsets.top + view.safeAreaInsets.bottom
                    #expect(view.bounds.height == max(size.height, minimumHeight))
                    #expect(!window.isVisible)
                    #expect(!window.isOpaque)
                    #expect(window.titlebarAppearsTransparent)
                    #expect(window.title.isEmpty)
                    if checksNavigationChrome { #expect(window.titleVisibility == .hidden) }
                    #expect(window.titlebarSeparatorStyle == .none)
                    let split = try #require(settingsSplitControllers(in: view).first)
                    #expect(split.splitViewItems.count == 2)
                    #expect(split.splitViewItems[0].allowsFullHeightLayout)
                    #expect(!split.splitViewItems[0].canCollapse)
                    #expect(split.sidebarHost.view.bounds.width >= 220)
                    #expect(split.detailHost.view.bounds.width >= 520)
                    let titleItem = try #require(window.toolbar?.items.first { $0.itemIdentifier.rawValue == "settings.pageTitle" })
                    #expect((titleItem.view as? NSTextField)?.stringValue == readinessText(category.titleKey))
                    #expect(titleItem.isNavigational)
                    let header = try #require(titleItem.view as? NSTextField)
                    #expect(header.font?.pointSize == 16)
                    let headerRect = header.convert(header.bounds, to: nil)
                    #expect(headerRect.minX < split.sidebarHost.view.bounds.width + 200)

                    #expect(window.toolbar?.items.contains { $0 is NSToolbarItemGroup } == true)

                    if category == .shortcuts {
                        let split = try #require(settingsSplitControllers(in: view).first)
                        let picker = try #require(settingsScopePickers(in: split.detailHost.view).first)
                        let rect = picker.convert(picker.bounds, to: nil)
                        // A full-size content view must keep interactive header controls below chrome.
                        #expect(rect.maxY <= window.contentLayoutRect.maxY)
                        let center = NSPoint(x: picker.bounds.midX, y: picker.bounds.midY)
                        let hit = picker.hitTest(picker.convert(center, to: picker.superview))
                        #expect(picker.visibleRect.contains(center))
                        #expect(hit === picker || hit?.isDescendant(of: picker) == true)
                        #expect(picker.selectedSegment == 0)
                        picker.selectedSegment = 1
                        picker.sendAction(picker.action, to: picker.target)
                        for _ in 0..<5 { try await Task.sleep(for: .milliseconds(20)); view.layoutSubtreeIfNeeded() }
                        #expect(picker.selectedSegment == 1)
                        #expect(settingsRecorders(in: split.detailHost.view).count == GlobalShortcutAction.allCases.count)
                        picker.selectedSegment = 0
                        picker.sendAction(picker.action, to: picker.target)
                        for _ in 0..<5 { try await Task.sleep(for: .milliseconds(20)); view.layoutSubtreeIfNeeded() }
                        #expect(picker.selectedSegment == 0)
                        #expect(settingsRecorders(in: split.detailHost.view).count == ShortcutSettings.localIDs.count)
                    }

                    let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                    view.cacheDisplay(in: view.bounds, to: bitmap)
                    let name = "settings-\(code)-\(dark ? "dark" : "light")-\(category.rawValue)-\(Int(size.width)).png"
                    try bitmap.representation(using: .png, properties: [:])?.write(to: output.appendingPathComponent(name))
                }

                if category == .appearance {
                    let split = try #require(settingsSplitControllers(in: view).first)
                    let title = try #require(window.toolbar?.items.first { $0.itemIdentifier.rawValue == "settings.pageTitle" }?.view as? NSTextField)
                    let scroll = try #require(settingsScrollViews(in: split.detailHost.view).first)
                    let top = scroll.contentView.bounds.origin
                    try await Task.sleep(for: .milliseconds(200))
                    #expect(title.alphaValue == 0)
                    scroll.contentView.scroll(to: NSPoint(x: top.x, y: top.y + 120))
                    scroll.reflectScrolledClipView(scroll.contentView)
                    for _ in 0..<10 { try await Task.sleep(for: .milliseconds(30)); view.layoutSubtreeIfNeeded() }
                    #expect(title.alphaValue == 1)
                    scroll.contentView.scroll(to: top)
                    scroll.reflectScrolledClipView(scroll.contentView)
                    for _ in 0..<10 { try await Task.sleep(for: .milliseconds(30)); view.layoutSubtreeIfNeeded() }
                    #expect(title.alphaValue == 0)
                }
                if category == .general {
                    let size = view.bounds.size
                    ShortcutSettings.shared.showShortcuts = true
                    for _ in 0..<5 { try await Task.sleep(for: .milliseconds(20)); view.layoutSubtreeIfNeeded() }
                    #expect(view.bounds.size == size)
                    let controller = try #require(settingsSplitControllers(in: view).first)
                    let title = try #require(window.toolbar?.items.first { $0.itemIdentifier.rawValue == "settings.pageTitle" }?.view as? NSTextField)
                    let history = try #require(window.toolbar?.items.compactMap { $0 as? NSToolbarItemGroup }.first)
                    #expect(title.stringValue == readinessText("Shortcuts"))
                    #expect(history.subitems[0].isEnabled)
                    #expect(!history.subitems[1].isEnabled)
                    history.selectedIndex = 0
                    app.sendAction(try #require(history.action), to: history.target, from: history)
                    for _ in 0..<5 { try await Task.sleep(for: .milliseconds(20)); view.layoutSubtreeIfNeeded() }
                    #expect(title.stringValue == readinessText("General"))
                    #expect(!history.subitems[0].isEnabled)
                    #expect(history.subitems[1].isEnabled)
                    history.selectedIndex = 1
                    app.sendAction(try #require(history.action), to: history.target, from: history)
                    for _ in 0..<5 { try await Task.sleep(for: .milliseconds(20)); view.layoutSubtreeIfNeeded() }
                    #expect(title.stringValue == readinessText("Shortcuts"))
                    #expect(settingsSplitControllers(in: view).first === controller)
                    #expect(view.bounds.size == size)

                    let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                    view.cacheDisplay(in: view.bounds, to: bitmap)
                    try bitmap.representation(using: .png, properties: [:])?.write(to: output.appendingPathComponent("settings-\(code)-\(dark ? "dark" : "light")-shortcut-route.png"))
                }
                window.contentView = nil; window.close()
            }
        }
    }
    #expect(!server.enabled)
    #expect(server.grants.isEmpty)
    #expect(storage.library === originalLibrary)
    #expect(login.status == .requiresApproval)
    ShortcutSettings.shared.showShortcuts = false
}

@MainActor private func settingsSplitControllers(in view: NSView) -> [SettingsSplitController] {
    if let split = view as? NSSplitView, let owner = split.delegate as? SettingsSplitController { return [owner] }
    return view.subviews.flatMap { settingsSplitControllers(in: $0) }
}

@Test func settingsNavigationHistoryBranchesAndBounds() {
    var history = SettingsNavigationHistory()
    history.visit(.general)
    history.visit(.appearance)
    history.visit(.storage)
    #expect(history.back() == .appearance)
    history.visit(.appearance)
    #expect(history.canGoForward)
    #expect(history.forward() == .storage)
    #expect(history.back() == .appearance)
    history.visit(.connections)
    #expect(!history.canGoForward)
    #expect(history.entries == [.general, .appearance, .connections])
    for index in 0..<100 { history.visit(index.isMultiple(of: 2) ? .general : .appearance) }
    #expect(history.entries.count == 64)
    for _ in 0..<63 { #expect(history.back() != nil) }
    #expect(history.back() == nil)
    #expect(history.canGoForward)
}

@MainActor private func settingsScrollViews(in view: NSView) -> [NSScrollView] {
    if let scroll = view as? NSScrollView { return [scroll] }
    return view.subviews.flatMap { settingsScrollViews(in: $0) }
}

@Test func settingsHeaderUsesScrollDistanceRatherThanRawOffset() {
    #expect(!SettingsHeaderLayout.showsTitle(offset: -52, inset: 52))
    #expect(!SettingsHeaderLayout.showsTitle(offset: -70, inset: 52))
    #expect(SettingsHeaderLayout.showsTitle(offset: -20, inset: 52))
    #expect(!SettingsHeaderLayout.showsTitle(offset: 0, inset: 0))
    #expect(SettingsHeaderLayout.showsTitle(offset: 40, inset: 0))
}

@MainActor private func settingsScopePickers(in view: NSView) -> [NSSegmentedControl] {
    if let picker = view as? NSSegmentedControl { return [picker] }
    return view.subviews.flatMap { settingsScopePickers(in: $0) }
}
@MainActor private func settingsRecorders(in view: NSView) -> [ShortcutRecorder] {
    if let recorder = view as? ShortcutRecorder { return [recorder] }
    return view.subviews.flatMap { settingsRecorders(in: $0) }
}
