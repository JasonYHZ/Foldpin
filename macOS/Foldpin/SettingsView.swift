import SwiftUI

/// Stable navigation identities, independent of localized labels and stored preferences.
enum SettingsCategory: String, CaseIterable, Identifiable {
    case general, appearance, shortcuts, storage, connections, about
    var id: String { rawValue }
    var titleKey: String {
        switch self {
        case .general: "General"
        case .appearance: "Appearance"
        case .shortcuts: "Shortcuts"
        case .storage: "Data and Storage"
        case .connections: "External AI Connections"
        case .about: "About and Help"
        }
    }
    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .appearance: "paintpalette"
        case .shortcuts: "keyboard"
        case .storage: "externaldrive"
        case .connections: "point.3.connected.trianglepath.dotted"
        case .about: "info.circle"
        }
    }
}

/// Per-window navigation; changing direction does not append another history entry.
struct SettingsNavigationHistory {
    private(set) var entries: [SettingsCategory] = []
    private(set) var index = -1
    var canGoBack: Bool { index > 0 }
    var canGoForward: Bool { index >= 0 && index + 1 < entries.count }
    mutating func visit(_ category: SettingsCategory) {
        guard index < 0 || entries[index] != category else { return }
        entries = Array(entries.prefix(index + 1))
        entries.append(category)
        if entries.count > 64 { entries.removeFirst() }
        index = entries.count - 1
    }
    mutating func back() -> SettingsCategory? {
        guard canGoBack else { return nil }
        index -= 1
        return entries[index]
    }
    mutating func forward() -> SettingsCategory? {
        guard canGoForward else { return nil }
        index += 1
        return entries[index]
    }
}

enum SettingsHeaderLayout {
    static func showsTitle(offset: CGFloat, inset: CGFloat) -> Bool {
        offset + inset > 8
    }
}

struct FoldpinSettingsView: View {
    @ObservedObject var mcp: MCPServer
    @ObservedObject var storage: LibraryLocationController
    @ObservedObject var login: LoginItemSettings
    let help: () -> Void
    let feedback: () -> Void
    let locate: (UUID) -> Void
    @State var selectedCategory: SettingsCategory? = .general
    @State private var navigation = SettingsNavigationHistory()
    @State private var showsScrolledTitle = false
    @ObservedObject private var shortcuts = ShortcutSettings.shared
    @ObservedObject private var language = LanguageSettings.shared
    var body: some View {
        SettingsWindowLayout(sidebar: AnyView(sidebar), detail: AnyView(detail),
            title: readinessText((selectedCategory ?? .general).titleKey), showsTitle: showsScrolledTitle,
            canGoBack: navigation.canGoBack, canGoForward: navigation.canGoForward,
            goBack: { if let category = navigation.back() { selectedCategory = category } },
            goForward: { if let category = navigation.forward() { selectedCategory = category } })
        .ignoresSafeArea()
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .navigationTitle("")
        .frame(minWidth: 780, idealWidth: 900, maxWidth: .infinity,
               minHeight: 560, idealHeight: 680, maxHeight: .infinity)
        .onChange(of: shortcuts.showShortcuts) { _, value in
            if value { selectedCategory = .shortcuts }
        }
        .onChange(of: selectedCategory) { _, value in
            showsScrolledTitle = false
            navigation.visit(value ?? .general)
            shortcuts.showShortcuts = value == .shortcuts
        }
        .onAppear {
            language.refresh()
            navigation.visit(selectedCategory ?? .general)
            if shortcuts.showShortcuts { selectedCategory = .shortcuts }
        }
        .environment(\.locale, language.locale)
    }

    private var sidebar: some View {
        List(SettingsCategory.allCases, selection: $selectedCategory) { category in
            HStack(spacing: 10) {
                Image(systemName: category.symbol)
                    .font(.system(size: 16, weight: .medium))
                    .frame(width: 28, height: 28)
                    .background(.primary.opacity(0.08), in: .rect(cornerRadius: 7))
                    .accessibilityHidden(true)
                Text(readinessText(category.titleKey))
                    .font(.system(size: 14, weight: .medium))
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 4)
            .tag(category)
            .accessibilityIdentifier("settings.category." + category.rawValue)
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .padding(.top, 18)
        .accessibilityLabel(readinessText("Settings categories"))
        .environment(\.locale, language.locale)
    }

    private var detail: some View {
        page
        // Let the scroll view extend under the actual toolbar. Its content
        // starts below the controls, but can scroll through the soft edge.
        .contentMargins(.top, 52, for: .scrollContent)
        .onScrollGeometryChange(for: Bool.self) { geometry in
            SettingsHeaderLayout.showsTitle(offset: geometry.contentOffset.y, inset: geometry.contentInsets.top)
        } action: { _, visible in
            showsScrolledTitle = visible
        }
        .scrollEdgeEffectStyle(.soft, for: .top)
        .scrollContentBackground(.hidden)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: SettingsWindowPalette.content))
        .ignoresSafeArea(.container, edges: .top)
        .environment(\.locale, language.locale)
    }

    @ViewBuilder private var page: some View {
        switch selectedCategory ?? .general {
        case .general: GeneralSettingsView(login: login)
        case .appearance: AppearanceSettingsView()
        case .shortcuts: ShortcutSettingsView()
        case .storage: LibraryStorageSettingsView(storage: storage, locate: locate)
        case .connections: MCPSettingsView(server: mcp)
        case .about: AboutSettingsView(help: help, feedback: feedback)
        }
    }
}

struct AboutSettingsView: View {
    let help: () -> Void
    let feedback: () -> Void
    @State private var showingLicenses = false
    @ObservedObject private var language = LanguageSettings.shared
    var body: some View {
        Form {
            Section {
                HStack(spacing: 16) {
                    Image(nsImage: NSImage(named: NSImage.applicationIconName) ?? NSImage())
                        .resizable().frame(width: 64, height: 64).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Foldpin").font(.headline)
                        Text(readinessText("Floating notes for your Mac.")).foregroundStyle(.secondary)
                    }
                }
                LabeledContent(readinessText("Version"), value: FeedbackController.version)
            }
            Section(readinessText("Help")) {
                Button(readinessText("User Guide"), action: help)
                Button(readinessText("Feedback…"), action: feedback)
                if Bundle.main.url(forResource: "ThirdPartyNotices", withExtension: "txt") != nil {
                    Button(readinessText("Licenses")) { showingLicenses = true }
                }
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $showingLicenses) {
            VStack(alignment: .leading, spacing: 16) {
                Text(readinessText("Licenses")).font(.title2.bold())
                ScrollView {
                    Text(licenseText).font(.system(.body, design: .monospaced))
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack { Spacer(); Button(readinessText("Done")) { showingLicenses = false }.keyboardShortcut(.defaultAction) }
            }.padding(24).frame(width: 580, height: 480)
        }
    }
    private var licenseText: String {
        let notices = ["LICENSE", "ThirdPartyNotices"].compactMap { name -> String? in
            guard let url = Bundle.main.url(forResource: name, withExtension: "txt") else { return nil }
            return try? String(contentsOf: url, encoding: .utf8)
        }
        return (["Foldpin — GPL-3.0-only\nCopyright (C) 2026 Foldpin contributors"] + notices)
            .joined(separator: "\n\n")
    }
}

/// AppKit owns the inset, rounded, full-height Liquid Glass sidebar and window chrome.
/// Keep the same two hosting controllers when preferences or selection change.
private struct SettingsWindowLayout: NSViewControllerRepresentable {
    let sidebar: AnyView
    let detail: AnyView
    let title: String
    let showsTitle: Bool
    let canGoBack: Bool
    let canGoForward: Bool
    let goBack: () -> Void
    let goForward: () -> Void
    func makeNSViewController(context: Context) -> SettingsSplitController {
        SettingsSplitController(sidebar: sidebar, detail: detail)
    }
    func updateNSViewController(_ controller: SettingsSplitController, context: Context) {
        controller.sidebarHost.rootView = sidebar
        controller.detailHost.rootView = detail
        controller.updateToolbar(title: title, showsTitle: showsTitle, canGoBack: canGoBack, canGoForward: canGoForward,
                                 goBack: goBack, goForward: goForward)
        controller.view.window?.title = ""
        controller.view.window?.titleVisibility = .hidden
    }
}

final class SettingsSplitController: NSSplitViewController, NSToolbarDelegate {
    let sidebarHost: NSHostingController<AnyView>
    let detailHost: NSHostingController<AnyView>
    private weak var configuredWindow: NSWindow?
    private let titleField = NSTextField(labelWithString: "")
    private var navigationGroup: NSToolbarItemGroup?
    private var canGoBack = false
    private var canGoForward = false
    private var goBack: () -> Void = {}
    private var goForward: () -> Void = {}
    init(sidebar: AnyView, detail: AnyView) {
        sidebarHost = NSHostingController(rootView: sidebar)
        detailHost = NSHostingController(rootView: detail)
        sidebarHost.sizingOptions = []
        detailHost.sizingOptions = []
        super.init(nibName: nil, bundle: nil)
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarHost)
        sidebarItem.minimumThickness = 220
        sidebarItem.maximumThickness = 280
        sidebarItem.preferredThicknessFraction = 0.28
        sidebarItem.canCollapse = false
        sidebarItem.canCollapseFromWindowResize = false
        sidebarItem.allowsFullHeightLayout = true
        sidebarItem.titlebarSeparatorStyle = .none
        sidebarItem.holdingPriority = NSLayoutConstraint.Priority(260)
        let detailItem = NSSplitViewItem(viewController: detailHost)
        detailItem.minimumThickness = 520
        detailItem.canCollapse = false
        detailItem.titlebarSeparatorStyle = .none
        addSplitViewItem(sidebarItem)
        addSplitViewItem(detailItem)
    }
    required init?(coder: NSCoder) { nil }
    private let sidebarBoundary = NSToolbarItem.Identifier("settings.sidebarBoundary")
    private let historyIdentifier = NSToolbarItem.Identifier("settings.navigation")
    private let titleIdentifier = NSToolbarItem.Identifier("settings.pageTitle")
    private var toolbarIdentifiers: [NSToolbarItem.Identifier] { [sidebarBoundary, historyIdentifier, titleIdentifier, .flexibleSpace] }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { toolbarIdentifiers }
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { toolbarIdentifiers }
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar: Bool) -> NSToolbarItem? {
        switch identifier {
        case sidebarBoundary:
            return NSTrackingSeparatorToolbarItem(identifier: identifier, splitView: splitView, dividerIndex: 0)
        case historyIdentifier:
            let group = NSToolbarItemGroup(itemIdentifier: identifier,
                images: [NSImage(systemSymbolName: "chevron.left", accessibilityDescription: nil)!,
                         NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)!],
                selectionMode: .momentary, labels: [readinessText("Back"), readinessText("Forward")],
                target: self, action: #selector(navigate(_:)))
            group.controlRepresentation = .expanded
            group.isNavigational = true
            group.autovalidates = false
            navigationGroup = group
            updateNavigationItems()
            return group
        case titleIdentifier:
            let item = NSToolbarItem(itemIdentifier: identifier)
            titleField.font = .systemFont(ofSize: 16, weight: .medium)
            titleField.sizeToFit()
            titleField.lineBreakMode = .byTruncatingTail
            titleField.setAccessibilityIdentifier("settings.toolbar.title")
            item.view = titleField
            item.isBordered = false
            // macOS separates navigation items from trailing toolbar actions.
            item.isNavigational = true
            item.visibilityPriority = .high
            return item
        default: return nil
        }
    }
    func updateToolbar(title: String, showsTitle: Bool, canGoBack: Bool, canGoForward: Bool,
                       goBack: @escaping () -> Void, goForward: @escaping () -> Void) {
        if titleField.stringValue != title {
            titleField.stringValue = title
            titleField.sizeToFit()
        }
        titleField.setAccessibilityElement(showsTitle)
        let opacity: CGFloat = showsTitle ? 1 : 0
        if titleField.alphaValue != opacity {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.15
                titleField.animator().alphaValue = opacity
            }
        }
        self.canGoBack = canGoBack
        self.canGoForward = canGoForward
        self.goBack = goBack
        self.goForward = goForward
        updateNavigationItems()
    }
    private func updateNavigationItems() {
        guard let group = navigationGroup else { return }
        for (index, enabled) in [canGoBack, canGoForward].enumerated() {
            let item = group.subitems[index]
            item.autovalidates = false
            item.isEnabled = enabled
            item.label = readinessText(index == 0 ? "Back" : "Forward")
            item.toolTip = item.label
        }
    }
    @objc private func navigate(_ sender: NSToolbarItemGroup) {
        if sender.selectedIndex == 0, canGoBack { goBack() }
        if sender.selectedIndex == 1, canGoForward { goForward() }
    }
    override func viewDidLayout() {
        super.viewDidLayout()
        guard let target = view.window, configuredWindow !== target else { return }
        configuredWindow = target
        DispatchQueue.main.async { [weak self, weak target] in
            guard let self, let target, self.view.window === target else { return }
            target.title = ""
            target.titlebarAppearsTransparent = true
            target.titleVisibility = .hidden
            target.titlebarSeparatorStyle = .none
            target.toolbarStyle = .unified
            target.styleMask.formUnion([.fullSizeContentView, .miniaturizable])
            let toolbar = NSToolbar(identifier: "Foldpin.Settings.Toolbar")
            toolbar.delegate = self
            toolbar.displayMode = .iconOnly
            toolbar.allowsUserCustomization = false
            target.toolbar = toolbar
            target.backgroundColor = SettingsWindowPalette.content
            target.isOpaque = false
        }
    }
}

private enum SettingsWindowPalette {
    static let content = NSColor(name: nil) { appearance in
        if appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
            return NSColor(srgbRed: 0.067, green: 0.071, blue: 0.094, alpha: 1)
        }
        return NSColor(srgbRed: 0.965, green: 0.967, blue: 0.976, alpha: 1)
    }
}
