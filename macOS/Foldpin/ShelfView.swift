import SwiftUI
import Combine
import AppKit

private func shelfText(_ key: String) -> String {
    String(localized: String.LocalizationValue(key), bundle: LanguageSettings.shared.bundle)
}

struct EdgeView: View {
    @ObservedObject var library: NoteLibrary
    var onOpen: () -> Void
    var body: some View {
        Button(action: onOpen) { Image(systemName: "rectangle.stack").padding(10) }
            .help(shelfText("Open Shelf"))
    }
}

struct ShelfSummary: Identifiable {
    let id: UUID
    let title: String
    let text: String
    let color: NoteColor
    let icon: String?
    let favorite: Bool
    let shelved: Bool
    let deleted: Bool
    let unreadable: Bool
    let modified: Date
    let created: Date
    let types: Set<String>
    init(_ entry: NoteLibrary.Entry) {
        let d = entry.store.document
        id = entry.id; text = d.content.plainText
        title = (d.conflictOf == nil ? "" : shelfText("Conflict copy") + " · ") + String(text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.first(where: { !$0.isEmpty })?.prefix(160) ?? "")
        color = d.color; icon = d.icon; favorite = d.isFavorite; shelved = d.isShelved
        deleted = d.deletedAt != nil; unreadable = entry.store.loadError != nil
        modified = d.modifiedAt; created = d.createdAt
        types = Set(d.content.blocks.map { block in
            switch block.kind {
            case .task: return "Tasks"
            case .code: return "Code"
            case .image: return "Images"
            case .audio: return "Audio"
            case .file: return "Attachments"
            case .video: return "Video"
            case .table: return "Tables"
            default: return "Text"
            }
        })
    }
    var displayTitle: String { unreadable ? shelfText("Could not load") : title.isEmpty ? shelfText("Blank Note") : title }
    var symbol: String {
        if types.contains("Attachments") { return "paperclip" }
        if types.contains("Audio") { return "waveform" }
        if types.contains("Video") { return "play.rectangle" }
        if types.contains("Images") { return "photo" }
        if types.contains("Code") { return "chevron.left.forwardslash.chevron.right" }
        if types.contains("Tasks") { return "checklist" }
        if types.contains("Tables") { return "tablecells" }
        return "note.text"
    }
    func excerpt(query: String) -> String {
        let source = text.replacingOccurrences(of: "\n\n", with: "\n")
        if !query.isEmpty, let match = source.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) {
            let start = source.index(match.lowerBound, offsetBy: -50, limitedBy: source.startIndex) ?? source.startIndex
            return (start == source.startIndex ? "" : "…") + String(source[start...].prefix(260))
        }
        let lines = source.split(separator: "\n", omittingEmptySubsequences: true)
        return String(lines.dropFirst().joined(separator: "\n").prefix(260))
    }
}

enum ShelfDateGroup: String, CaseIterable {
    case today = "Today", yesterday = "Yesterday", week = "Previous 7 Days"
    case month = "Previous 30 Days", earlier = "Earlier"
    static func containing(_ date: Date, now: Date = Date(), calendar: Calendar = .autoupdatingCurrent) -> Self {
        let age = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 0
        switch age {
        case ...0: return .today
        case 1: return .yesterday
        case 2...7: return .week
        case 8...30: return .month
        default: return .earlier
        }
    }
}
struct ShelfDateSection: Identifiable {
    let id: String
    let title: String?
    var items: [ShelfSummary]
}

enum ShelfDestination: Hashable {
    case all, desktop, shelved, favorites, deleted, collection(UUID)
    var label: String {
        switch self {
        case .all: return shelfText("All Notes")
        case .desktop: return shelfText("On Desktop")
        case .shelved: return shelfText("On Shelf")
        case .favorites: return shelfText("Favorites")
        case .deleted: return shelfText("Recently Deleted")
        case .collection: return shelfText("Collection")
        }
    }
}

@MainActor
private final class LibraryWindow: NSWindow {
    var onFind: (() -> Void)?
    var onSelectAll: (() -> Bool)?
    var onActions: (() -> Bool)?
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .shift, .control, .option])
        if isKeyWindow, flags == .command, event.charactersIgnoringModifiers?.lowercased() == "f" {
            onFind?(); return true
        }
        if isKeyWindow, flags == .command, event.charactersIgnoringModifiers?.lowercased() == "a",
           onSelectAll?() == true { return true }
        if isKeyWindow, ShortcutSettings.shared.matchingNote(event) == .actions,
           onActions?() == true { return true }
        return super.performKeyEquivalent(with: event)
    }
}

/// The document divider belongs below the titlebar, while the outer native
/// sidebar keeps its full-height glass and tracking toolbar separator.
@MainActor
private final class LibraryContentController: NSViewController {
    init(split: NSSplitViewController) {
        super.init(nibName: nil, bundle: nil)
        view = NSView()
        addChild(split)
        let content = split.view
        content.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            content.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            content.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }
    required init?(coder: NSCoder) { nil }
}

@MainActor
final class ShelfPreviewWindow: NSObject, NSWindowDelegate, ObservableObject, NSToolbarDelegate, NSSearchFieldDelegate {
    let library: NoteLibrary
    let collections: NoteCollections
    let noteActionsState = NoteTitlebarState()
    private let noteActionsPanel = NoteActionsPanel()
    @Published private(set) var selectedEntry: NoteLibrary.Entry? { willSet { noteActionsPanel.close() } }
    @Published var selected: PaperWindowController?
    var editing: Bool { selected?.session.inPreview == true }
    @Published private(set) var summaries: [ShelfSummary] = []
    @Published private(set) var destination: ShelfDestination = .all
    @Published private(set) var query = ""
    @Published private(set) var typeFilter = "All Types"
    @Published var sort = "Recently Modified"
    @Published var grid = true
    @Published var sidebar = true { didSet { updateSidebarVisibility() } }
    @Published var multiple = false
    @Published var picked: Set<UUID> = [] { didSet { if !marqueeActive { refreshToolbar() } } }
    var marqueeActive = false
    private var selectionAnchor: UUID?
    private var frozenDates: [UUID: (created: Date, modified: Date)]?
    private var frozenGroupingDate: Date?
    private func freezeDates() {
        frozenDates = Dictionary(uniqueKeysWithValues: summaries.map { ($0.id, (created: $0.created, modified: $0.modified)) })
        frozenGroupingDate = Date()
    }
    private func orderingDate(_ item: ShelfSummary) -> Date {
        let byCreated = sort == "Recently Created" || sort == "Oldest Created"
        let dates = frozenDates?[item.id]
        return byCreated ? (dates?.created ?? item.created) : (dates?.modified ?? item.modified)
    }
    func sections(grouped: Bool, now: Date = Date()) -> [ShelfDateSection] {
        let items = results
        guard grouped else { return items.isEmpty ? [] : [ShelfDateSection(id: "all", title: nil, items: items)] }
        var sections: [ShelfDateSection] = []
        for item in items {
            let key = ShelfDateGroup.containing(orderingDate(item), now: frozenGroupingDate ?? now).rawValue
            if sections.last?.id == key { sections[sections.count - 1].items.append(item) }
            else { sections.append(ShelfDateSection(id: key, title: key, items: [item])) }
        }
        return sections
    }
    var selectedSummaries: [ShelfSummary] { results.filter { picked.contains($0.id) } }
    var showsSelectionSummary: Bool { multiple && !picked.isEmpty }
    var showsDetail: Bool { selectedEntry != nil || showsSelectionSummary }
    @Published var feedback: String?
    private(set) var window: NSWindow!
    private let resolve: (UUID) -> PaperWindowController?
    private let existingController: (UUID) -> PaperWindowController?
    private let onPermanentlyDeleted: (UUID) -> Void
    var onImport: (() -> Void)?
    private let onNew: () -> Void
    private let onRetry: () -> Void
    private var subscriptions: [AnyCancellable] = []
    private var entrySubscriptions: [AnyCancellable] = []
    private var search = NSSearchField()
    private var searchExpanded = false
    private var viewSwitch = NSSegmentedControl()
    private var toolbarTitle = NSTextField(labelWithString: "")
    private let splitController = NSSplitViewController()
    private var sidebarItem: NSSplitViewItem!
    private let detailSplitController = NSSplitViewController()
    private var browserItem: NSSplitViewItem!
    private var previewItem: NSSplitViewItem!
    private var previewWidth: CGFloat = 340
    private var updatingColumns = false
    private let separatorID = NSToolbarItem.Identifier("shelf.sidebar.separator")
    private let newID = NSToolbarItem.Identifier("shelf.new")
    private let sidebarID = NSToolbarItem.Identifier("shelf.sidebar")
    private let titleID = NSToolbarItem.Identifier("shelf.title")
    private let viewID = NSToolbarItem.Identifier("shelf.view")
    private let searchID = NSToolbarItem.Identifier("shelf.search")

    init(library: NoteLibrary, resolve: @escaping (UUID) -> PaperWindowController?,
         onNew: @escaping () -> Void, onRetry: @escaping () -> Void, onRestore: @escaping (UUID) -> Void, existingController: @escaping (UUID) -> PaperWindowController? = { _ in nil }, onPermanentlyDeleted: @escaping (UUID) -> Void = { _ in }) {
        self.onPermanentlyDeleted = onPermanentlyDeleted
        self.existingController = existingController
        self.library = library; self.resolve = resolve; self.onNew = onNew; self.onRetry = onRetry
        collections = NoteCollections(directory: library.directory, libraryPath: library.path)
        super.init()
        window = LibraryWindow(contentRect: NSRect(x: 0, y: 0, width: 1240, height: 780),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 740, height: 500)
        window.titlebarAppearsTransparent = true
        window.toolbarStyle = .unified
        window.titleVisibility = .hidden
        window.isOpaque = false
        window.backgroundColor = .windowBackgroundColor
        window.titlebarSeparatorStyle = .none
        window.delegate = self
        (window as? LibraryWindow)?.onFind = { [weak self] in
            guard let self else { return }
            if editing { selected?.session.host.editor.performEditorShortcut(.find) }
            else { activateSearch() }
        }
        (window as? LibraryWindow)?.onSelectAll = { [weak self] in self?.selectAllIfBrowsing() ?? false }
        (window as? LibraryWindow)?.onActions = { [weak self] in
            guard let self, let entry = selectedEntry, entry.store.document.deletedAt == nil else { return false }
            toggleNoteActions(entry.id)
            return true
        }
        // Let AppKit own the floating sidebar glass, safe areas and titlebar sections.
        // A full-window glass wrapper hides that native sidebar treatment.
        let sidebarController = NSHostingController(rootView: ShelfSidebar(owner: self, collections: collections))
        sidebarController.sizingOptions = []
        sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarController)
        sidebarItem.minimumThickness = 210
        sidebarItem.maximumThickness = 360
        sidebarItem.canCollapse = false
        sidebarItem.canCollapseFromWindowResize = false
        sidebarItem.allowsFullHeightLayout = true
        sidebarItem.titlebarSeparatorStyle = .none
        // Stay below AppKit’s divider-drag priority (490), so dragging can resize it.
        sidebarItem.holdingPriority = NSLayoutConstraint.Priority(260)
        let browserController = NSHostingController(rootView: ShelfView(owner: self, collections: collections))
        browserController.sizingOptions = []
        browserItem = NSSplitViewItem(viewController: browserController)
        browserItem.minimumThickness = 300
        browserItem.canCollapse = false
        browserItem.canCollapseFromWindowResize = false
        let previewController = NSHostingController(rootView: ShelfPreviewPane(owner: self, collections: collections))
        previewController.sizingOptions = []
        previewItem = NSSplitViewItem(viewController: previewController)
        previewItem.minimumThickness = 280
        previewItem.maximumThickness = 600
        previewItem.holdingPriority = NSLayoutConstraint.Priority(260)
        previewItem.canCollapse = false
        previewItem.canCollapseFromWindowResize = false
        detailSplitController.splitView.isVertical = true
        detailSplitController.splitView.dividerStyle = .thin
        detailSplitController.addSplitViewItem(browserItem)
        detailSplitController.addSplitViewItem(previewItem)
        let contentItem = NSSplitViewItem(viewController: LibraryContentController(split: detailSplitController))
        contentItem.minimumThickness = 460
        contentItem.titlebarSeparatorStyle = .none
        splitController.splitView.isVertical = true
        splitController.splitView.dividerStyle = .thin
        splitController.addSplitViewItem(sidebarItem)
        splitController.addSplitViewItem(contentItem)
        window.contentViewController = splitController
        splitController.splitView.setPosition(230, ofDividerAt: 0)
        let toolbar = NSToolbar(identifier: "Foldpin.Library.Toolbar")
        toolbar.delegate = self; toolbar.displayMode = .iconOnly; toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
        window.center()
        // Never initialize editors while deriving rows/cards.
        subscriptions.append(library.$entries.combineLatest(library.$deletedEntries).sink { [weak self] _, _ in
            DispatchQueue.main.async { self?.observeEntries() }
        })
        subscriptions.append(collections.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.objectWillChange.send(); self?.refreshToolbar() }
        })
        subscriptions.append(LanguageSettings.shared.$configuration.sink { [weak self] _ in
            DispatchQueue.main.async { self?.refreshToolbar(); self?.objectWillChange.send() }
        })
        subscriptions.append(NotificationCenter.default.publisher(for: NSSplitView.didResizeSubviewsNotification,
            object: detailSplitController.splitView).sink { [weak self] _ in
                guard let self, !updatingColumns, !previewItem.isCollapsed, !browserItem.isCollapsed,
                      window.frame.width >= 900 else { return }
                let width = previewItem.viewController.view.frame.width
                if width >= 280 && width <= 600 { previewWidth = width }
            })
        for name in [Notification.Name.NSCalendarDayChanged, NSNotification.Name.NSSystemTimeZoneDidChange, NSApplication.didBecomeActiveNotification] {
            subscriptions.append(NotificationCenter.default.publisher(for: name).sink { [weak self] _ in
                self?.objectWillChange.send()
            })
        }
        updateSidebarVisibility(); observeEntries(); refreshToolbar()
    }

    var title: String {
        if case .collection(let id) = destination { return collections.collections.first { $0.id == id }?.name ?? shelfText("Collection") }
        return destination.label
    }
    var results: [ShelfSummary] {
        let members: Set<UUID>?
        if case .collection(let id) = destination { members = collections.collections.first { $0.id == id }?.members ?? [] } else { members = nil }
        return summaries.filter { item in
            let scope: Bool
            switch destination {
            case .all: scope = !item.deleted
            case .desktop: scope = !item.deleted && !item.shelved
            case .shelved: scope = !item.deleted && item.shelved
            case .favorites: scope = !item.deleted && item.favorite
            case .deleted: scope = item.deleted
            case .collection: scope = !item.deleted && members?.contains(item.id) == true
            }
            return scope && (typeFilter == "All Types" || item.types.contains(typeFilter))
                && (query.isEmpty || item.text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil)
        }.sorted { a, b in
            let ascending = sort == "Oldest Modified" || sort == "Oldest Created"
            let first = orderingDate(a), second = orderingDate(b)
            return first == second ? a.id.uuidString < b.id.uuidString : ascending ? first < second : first > second
        }
    }
    func count(_ scope: ShelfDestination) -> Int {
        summaries.filter { item in
            switch scope {
            case .all: return !item.deleted
            case .desktop: return !item.deleted && !item.shelved
            case .shelved: return !item.deleted && item.shelved
            case .favorites: return !item.deleted && item.favorite
            case .deleted: return item.deleted
            case .collection(let id): return !item.deleted && collections.collections.first(where: { $0.id == id })?.members.contains(item.id) == true
            }
        }.count
    }
    private func observeEntries() {
        entrySubscriptions = (library.entries + library.deletedEntries).map { entry in
            entry.store.$document.dropFirst().debounce(for: .milliseconds(120), scheduler: RunLoop.main).sink { [weak self] _ in self?.rebuild() }
        }
        rebuild()
    }
    func rebuild() {
        summaries = (library.entries + library.deletedEntries).map(ShelfSummary.init)
        if multiple && !marqueeActive { picked.formIntersection(Set(results.map(\.id))) }
        refreshToolbar()
    }
    func show() { refreshToolbar(); NSApp.activate(); window.makeKeyAndOrderFront(nil); selected?.session.librarySlot?.claimEditor() }
    func select(_ id: UUID, modifiers: NSEvent.ModifierFlags? = nil) {
        let flags = modifiers ?? NSApp.currentEvent?.modifierFlags ?? []
        if flags.contains(.command) || flags.contains(.shift) {
            guard finish() else { return }
            var next = multiple ? picked : Set(selectedEntry.map { [$0.id] } ?? [])
            if flags.contains(.shift), let anchor = selectionAnchor,
               let first = results.firstIndex(where: { $0.id == anchor }), let last = results.firstIndex(where: { $0.id == id }) {
                next.formUnion(results[min(first, last)...max(first, last)].map(\.id))
            } else { if !next.insert(id).inserted { next.remove(id) }; selectionAnchor = id }
            selectedEntry = nil; selected = nil; multiple = true; picked = next
            return
        }
        multiple = false; picked = []; selectionAnchor = id
        if selectedEntry?.id == id { if frozenDates == nil { freezeDates() }; selected?.session.librarySlot?.claimEditor(); return }
        guard finish(), let entry = (library.entries + library.deletedEntries).first(where: { $0.id == id }) else { return }
        freezeDates()
        selectedEntry = entry
        selected = entry.store.document.deletedAt == nil ? resolve(id) : nil
        refreshToolbar()
    }
    /// Field editors (including search and rename) and paper editors retain ⌘A.
    func selectAllIfBrowsing() -> Bool {
        guard !(window.firstResponder is NSTextView) else { return false }
        selectAllNotes()
        return true
    }
    func selectAllNotes() {
        guard !marqueeActive, finish() else { return }
        selectedEntry = nil; selected = nil
        multiple = !results.isEmpty
        selectionAnchor = results.first?.id
        picked = Set(results.map(\.id))
    }
    @discardableResult func beginMarquee() -> Bool {
        // Preserve the geometry seen at mouse-down, including an edited note's
        // old group, until the rectangle has finished selecting its targets.
        guard selected?.session.endPreview() != false else { return false }
        if frozenDates == nil { freezeDates() }
        marqueeActive = true
        return true
    }
    func applyMarquee(_ hits: Set<UUID>, base: Set<UUID>, modifiers: NSEvent.ModifierFlags) {
        let next = modifiers.contains(.command) ? base.symmetricDifference(hits)
            : modifiers.contains(.shift) ? base.union(hits) : hits
        if !multiple { multiple = true }
        if picked != next { picked = next }
    }
    func endMarquee() {
        selectedEntry = nil; selected = nil
        marqueeActive = false
        frozenDates = nil; frozenGroupingDate = nil
        if picked.isEmpty { multiple = false }
        refreshToolbar()
    }
    @discardableResult func finish() -> Bool {
        noteActionsPanel.close()
        guard selected?.session.endPreview() != false else { return false }
        if frozenDates != nil { frozenDates = nil; frozenGroupingDate = nil; rebuild() }
        return true
    }
    func closePreview() { guard finish() else { return }; selectedEntry = nil; selected = nil; picked = []; multiple = false; refreshToolbar() }
    func navigate(_ next: ShelfDestination) {
        guard finish() else { return }
        selectedEntry = nil; selected = nil; multiple = false; picked = []
        destination = next; selectionAnchor = nil; refreshToolbar()
    }
    func filter(_ next: String) {
        guard finish() else { return }
        typeFilter = next; multiple = false; picked = []; closePreview()
    }
    func controlTextDidChange(_ notification: Notification) {
        guard finish() else { search.stringValue = query; return }
        query = search.stringValue; picked = []; multiple = false; closePreview()
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { finish() }
    func windowDidResize(_ notification: Notification) { updateSidebarVisibility() }
    private func updateSidebarVisibility() {
        guard let sidebarItem, let previewItem, let browserItem, let window, !updatingColumns, !marqueeActive else { return }
        updatingColumns = true
        defer { updatingColumns = false }
        // Selection changes only the right pane's contents, never column geometry.
        let visible = sidebar && window.frame.width >= 980
        if sidebarItem.isCollapsed == visible { sidebarItem.isCollapsed = !visible }
        if browserItem.isCollapsed { browserItem.isCollapsed = false }
        if previewItem.isCollapsed { previewItem.isCollapsed = false }
        detailSplitController.view.layoutSubtreeIfNeeded()
        let split = detailSplitController.splitView
        let width = min(previewWidth, max(280, split.bounds.width - 300 - split.dividerThickness))
        if abs(previewItem.viewController.view.frame.width - width) > 0.5 {
            split.setPosition(split.bounds.width - width - split.dividerThickness, ofDividerAt: 0)
        }
    }

    func noteActionSections(_ id: UUID) -> [ActionPaletteSection] {
        guard let entry = library.entry(id), entry.store.document.deletedAt == nil else { return [] }
        let document = entry.store.document
        let readable = entry.store.loadError == nil
        var noteItems = [
            ActionPaletteItem(id: "open", title: shelfText(document.isShelved ? "Open on Desktop" : "Locate Desktop Note"), symbol: "arrow.up.right.square", enabled: readable),
            ActionPaletteItem(id: "openHide", title: shelfText("Open and Hide Library"), symbol: "macwindow.on.rectangle", enabled: readable)
        ]
        if !document.isShelved { noteItems.append(ActionPaletteItem(id: "shelve", title: shelfText("Shelve"), symbol: "tray.and.arrow.down", enabled: readable)) }
        let favorite = ActionPaletteItem(id: "favorite", title: shelfText(document.isFavorite ? "Remove Favorite" : "Favorite"),
            symbol: document.isFavorite ? "star.fill" : "star", enabled: readable)
        let memberships = collections.collections.map { collection in
            ActionPaletteItem(id: "collection:" + collection.id.uuidString, title: collection.displayName, symbol: "folder",
                checked: collection.members.contains(id), enabled: readable)
        } + [ActionPaletteItem(id: "newCollection", title: shelfText("New Collection"), symbol: "folder.badge.plus", enabled: readable)]
        return [
            ActionPaletteSection(title: shelfText("Current Note"), items: noteItems + [favorite, ActionPaletteItem(id: "export", title: shelfText("Export Content…"), symbol: "square.and.arrow.up", enabled: readable)]),
            ActionPaletteSection(title: shelfText("Collections"), items: memberships),
            ActionPaletteSection(title: shelfText("Current Note"), items: [ActionPaletteItem(id: "delete", title: shelfText("Delete Note"), symbol: "trash", enabled: readable, destructive: true)])
        ]
    }
    func toggleNoteActions(_ id: UUID) {
        guard selectedEntry?.id == id, let entry = library.entry(id), entry.store.document.deletedAt == nil else { return }
        if noteActionsPanel.isShown { noteActionsPanel.close(restoringFocus: true); return }
        noteActionsState.isActionsPresented = true
        noteActionsPanel.onClose = { [weak state = noteActionsState] in state?.isActionsPresented = false }
        noteActionsPanel.show(in: window, anchorView: noteActionsState.actionsAnchor, store: entry.store,
            isEnabled: { _ in false }, perform: { _ in }, customSections: noteActionSections(id),
            performCustom: { [weak self] action in self?.performNoteMenuAction(action, noteID: id) })
    }
    func performNoteMenuAction(_ action: String, noteID id: UUID) {
        // A queued action remains bound to the paper that opened this panel.
        guard selectedEntry?.id == id, let entry = library.entry(id), entry.store.document.deletedAt == nil,
              entry.store.loadError == nil else { return }
        switch action {
        case "open": open(id)
        case "openHide": open(id, hideLibrary: true)
        case "shelve": _ = shelve(id); rebuild()
        case "favorite": favorite(id, !entry.store.document.isFavorite)
        case "export": exportNotes(ids: [id])
        case "newCollection": editCollection()
        case "delete": _ = delete(id)
        default:
            guard action.hasPrefix("collection:"), let collectionID = UUID(uuidString: String(action.dropFirst("collection:".count))),
                  let collection = collections.collections.first(where: { $0.id == collectionID }) else { return }
            membership(collectionID, ids: [id], included: !collection.members.contains(id))
        }
    }

    func open(_ id: UUID, hideLibrary: Bool = false) {
        guard finish(), let controller = resolve(id) else { return }
        controller.showPaper(focus: true)
        if hideLibrary && controller.isVisible { window.orderOut(nil) }
        rebuild()
    }
    func shelve(_ id: UUID) -> Bool {
        guard let entry = library.entry(id) else { return false }
        if entry.store.document.isShelved { return true }
        guard let controller = resolve(id) else { return false }
        return controller.shelvePaper(restoringFocus: false)
    }
    func delete(_ id: UUID) -> Bool {
        if selectedEntry?.id == id && !finish() { return false }
        guard let controller = resolve(id), controller.prepareToTerminate(), library.deleteNote(id) else { return false }
        controller.hideDeletedPaper()
        if selectedEntry?.id == id { closePreview() }
        rebuild(); return true
    }
    func restore(_ id: UUID) -> Bool {
        guard library.restoreNote(id, toShelf: true) != nil else { return false }
        if selectedEntry?.id == id { closePreview() }
        rebuild(); return true
    }
    func favorite(_ id: UUID, _ value: Bool) {
        guard let entry = library.entry(id) else { return }
        if !entry.store.setFavorite(value) { feedback = entry.store.saveError ?? shelfText("Could not save changes") }
        rebuild()
    }
    var permanentDeletionTargets: Set<UUID> {
        guard destination == .deleted else { return [] }
        let deleted = Set(library.deletedEntries.map(\.id))
        if multiple && !picked.isEmpty { return picked.intersection(deleted) }
        if let id = selectedEntry?.id { return deleted.intersection([id]) }
        return deleted
    }
    func confirmPermanentDeletion(ids: Set<UUID>? = nil) {
        guard destination == .deleted, window.attachedSheet == nil else { return }
        let targets = (ids ?? permanentDeletionTargets).intersection(Set(library.deletedEntries.map(\.id)))
        guard !targets.isEmpty else { return }
        let alert = NSAlert(); alert.alertStyle = .warning
        alert.messageText = String(format: shelfText("Permanently delete %lld notes?"), targets.count)
        alert.informativeText = shelfText("These notes will be removed from Recently Deleted and cannot be restored or undone.")
        alert.addButton(withTitle: shelfText("Cancel"))
        let remove = alert.addButton(withTitle: shelfText("Delete Permanently")); remove.hasDestructiveAction = true
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertSecondButtonReturn else { return }
            self?.permanentlyDelete(ids: targets)
        }
    }
    func permanentlyDelete(ids: Set<UUID>) {
        var removed: Set<UUID> = []
        var failures = 0
        for id in ids {
            do {
                try library.permanentlyDeleteNote(id)
                removed.insert(id)
                existingController(id)?.dispose()
                onPermanentlyDeleted(id)
            } catch { failures += 1 }
        }
        if let id = selectedEntry?.id, removed.contains(id) { selectedEntry = nil; selected = nil }
        picked.subtract(removed)
        if picked.isEmpty { multiple = false }
        if let anchor = selectionAnchor, removed.contains(anchor) { selectionAnchor = nil }
        feedback = String(format: shelfText("%lld permanently deleted, %lld failed"), removed.count, failures)
        rebuild(); refreshToolbar()
    }

    func exportNotes(ids: Set<UUID>) {
        noteActionsPanel.close(restoringFocus: true)
        do { NoteExportPresenter.present(try exportSources(ids: ids), in: window) }
        catch { NoteExportPresenter.showError(error, in: window) }
    }
    func exportSources(ids: Set<UUID>) throws -> [NoteExportSource] {
        let entries = library.entries.filter { ids.contains($0.id) }
        guard !entries.isEmpty, entries.count == ids.count else { throw NoteExportError.unavailable }
        var sources: [NoteExportSource] = []
        for entry in entries {
            let controller = existingController(entry.id) ?? (selectedEntry?.id == entry.id ? selected : nil)
            let source: NoteExportSource?
            if let controller { source = controller.exportSource() }
            else if entry.store.loadError == nil, entry.store.flush() {
                source = NoteExportSource(document: entry.store.document, assets: entry.store.file.assetsURL)
            } else { source = nil }
            guard let source else { throw NoteExportError.unavailable }
            sources.append(source)
        }
        return sources
    }

    func batch(_ action: String, ids: Set<UUID>? = nil) {
        guard finish() else { return }
        let targets = ids ?? picked
        var failures = 0
        for id in targets {
            let success: Bool
            switch action {
            case "Open on Desktop":
                if let controller = resolve(id) { controller.showPaper(focus: false); success = controller.isVisible } else { success = false }
            case "Shelve": success = shelve(id)
            case "Restore Note": success = restore(id)
            default: success = delete(id)
            }
            if !success { failures += 1 }
        }
        feedback = String(format: shelfText("%lld completed, %lld failed"), targets.count - failures, failures)
        rebuild()
    }
    func editCollection(_ id: UUID? = nil) {
        let alert = NSAlert()
        alert.messageText = shelfText(id == nil ? "New Collection" : "Rename Collection")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.stringValue = collections.collections.first { $0.id == id }?.name ?? ""
        alert.accessoryView = field
        alert.addButton(withTitle: shelfText("Save")); alert.addButton(withTitle: shelfText("Cancel"))
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            let success: Bool
            if let id { success = collections.rename(id, to: field.stringValue) }
            else { success = collections.create(field.stringValue) != nil }
            if !success { feedback = shelfText("Use a unique, nonempty collection name.") }
        }
        window.makeFirstResponder(field)
    }
    func removeCollection(_ id: UUID) {
        guard collections.remove(id) else { feedback = collections.error?.localizedDescription; return }
        if destination == .collection(id) { navigate(.all) }
    }
    func membership(_ id: UUID, ids: Set<UUID>, included: Bool) {
        if !collections.setMembership(ids, collection: id, included: included) { feedback = collections.error?.localizedDescription }
        objectWillChange.send()
    }
    @objc private func toggleSidebar() {
        if sidebarItem.isCollapsed, window.frame.width < 980 {
            var frame = window.frame
            frame.size.width = 980
            window.setFrame(frame, display: true)
            sidebar = true
        } else { sidebar.toggle() }
    }
    func revealNote(_ id: UUID) {
        guard finish() else { return }
        navigate(library.deletedEntries.contains(where: { $0.id == id }) ? .deleted : .all)
        query = ""; search.stringValue = ""; typeFilter = "All Types"
        rebuild(); select(id, modifiers: [])
    }
    @objc private func newNote() { onNew() }
    @objc private func importMarkdown() { onImport?() }
    private func newNoteMenu() -> NSMenu {
        let menu = NSMenu()
        for (title, action) in [("New Note", #selector(newNote)), ("Import Markdown…", #selector(importMarkdown))] {
            let item = NSMenuItem(title: shelfText(title), action: action, keyEquivalent: "")
            item.target = self; menu.addItem(item)
        }
        return menu
    }
    @objc private func changeView() { grid = viewSwitch.selectedSegment == 0 }
    func retry() { onRetry(); collections.reload(); rebuild() }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [sidebarID, separatorID, titleID, .flexibleSpace, viewID, .space, searchID, .space, newID] }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { toolbarDefaultItemIdentifiers(toolbar) }
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        if id == separatorID {
            return NSTrackingSeparatorToolbarItem(identifier: id, splitView: splitController.splitView, dividerIndex: 0)
        }
        let item: NSToolbarItem = id == newID ? NSMenuToolbarItem(itemIdentifier: id) : NSToolbarItem(itemIdentifier: id)
        switch id {
        case sidebarID:
            item.image = NSImage(systemSymbolName: "sidebar.left", accessibilityDescription: shelfText("Toggle Sidebar"))
            item.label = shelfText("Toggle Sidebar"); item.target = self; item.action = #selector(toggleSidebar)
        case titleID:
            toolbarTitle.font = .systemFont(ofSize: 15, weight: .semibold)
            toolbarTitle.lineBreakMode = .byTruncatingTail
            toolbarTitle.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            item.view = toolbarTitle
            item.isBordered = false
            item.visibilityPriority = .high
        case viewID:
            viewSwitch = NSSegmentedControl(images: [NSImage(systemSymbolName: "square.grid.2x2", accessibilityDescription: shelfText("Grid"))!,
                NSImage(systemSymbolName: "list.bullet", accessibilityDescription: shelfText("List"))!], trackingMode: .selectOne, target: self, action: #selector(changeView))
            viewSwitch.selectedSegment = grid ? 0 : 1
            viewSwitch.segmentStyle = .separated
            viewSwitch.setWidth(34, forSegment: 0); viewSwitch.setWidth(34, forSegment: 1)
            item.view = viewSwitch; item.label = shelfText("View")
        case searchID:
            search = NSSearchField(frame: NSRect(x: 0, y: 0, width: 230, height: 28))
            search.delegate = self; search.placeholderString = shelfText("Search notes…")
            search.sendsSearchStringImmediately = true
            configureSearchItem(item)
        case newID:
            item.image = NSImage(systemSymbolName: "square.and.pencil", accessibilityDescription: shelfText("New Note"))
            item.label = shelfText("New Note"); item.target = self; item.action = #selector(newNote)
            (item as? NSMenuToolbarItem)?.menu = newNoteMenu()
        default: return nil
        }
        return item
    }
    private func configureSearchItem(_ item: NSToolbarItem) {
        item.label = shelfText("Search notes…"); item.toolTip = item.label
        if searchExpanded {
            item.image = nil
            item.view = search
        } else {
            item.view = nil
            item.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: item.label)
            item.target = self; item.action = #selector(activateSearch)
        }
    }
    @objc func activateSearch() {
        searchExpanded = true
        if let item = window.toolbar?.items.first(where: { $0.itemIdentifier == searchID }) { configureSearchItem(item) }
        window.contentView?.superview?.layoutSubtreeIfNeeded()
        window.makeFirstResponder(search)
    }
    private func collapseEmptySearch() {
        guard query.isEmpty, search.stringValue.isEmpty, searchExpanded else { return }
        searchExpanded = false
        if let item = window.toolbar?.items.first(where: { $0.itemIdentifier == searchID }) { configureSearchItem(item) }
    }
    func controlTextDidEndEditing(_ notification: Notification) {
        guard notification.object as? NSSearchField === search else { return }
        // Defer until AppKit has moved the field editor to its new responder.
        DispatchQueue.main.async { [weak self] in
            guard let self, search.currentEditor() == nil else { return }
            collapseEmptySearch()
        }
    }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy command: Selector) -> Bool {
        guard control === search, command == #selector(NSResponder.cancelOperation(_:)), !textView.hasMarkedText() else { return false }
        search.stringValue = ""
        controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: search))
        guard query.isEmpty else { return true } // Save protection may reject changing the query.
        window.makeFirstResponder(nil)
        collapseEmptySearch()
        return true
    }
    private func refreshToolbar() {
        window.title = title; toolbarTitle.stringValue = title
        search.placeholderString = shelfText("Search notes…")
        for item in window.toolbar?.items ?? [] {
            if item.itemIdentifier == newID { (item as? NSMenuToolbarItem)?.menu = newNoteMenu() }
            if item.itemIdentifier == searchID { item.label = shelfText("Search notes…"); item.toolTip = item.label }
            if item.itemIdentifier == newID { item.label = shelfText("New Note"); item.toolTip = item.label; item.isEnabled = library.canCreate }
            if item.itemIdentifier == sidebarID { item.label = shelfText("Toggle Sidebar"); item.toolTip = item.label }
        }
    }
}

struct ShelfView: View {
    @ObservedObject var owner: ShelfPreviewWindow
    @ObservedObject var collections: NoteCollections
    @ObservedObject private var language = LanguageSettings.shared
    var body: some View {
        ShelfBrowser(owner: owner, collections: collections)
            .environment(\.locale, language.locale)
    }
}

private struct ShelfPreviewPane: View {
    @ObservedObject var owner: ShelfPreviewWindow
    @ObservedObject var collections: NoteCollections
    @ObservedObject private var language = LanguageSettings.shared
    var body: some View {
        Group {
            if owner.showsSelectionSummary { ShelfSelectionSummary(owner: owner, collections: collections) }
            else if owner.selectedEntry != nil { ShelfDetail(owner: owner, collections: collections) }
            else {
                VStack(spacing: 12) {
                    Image(systemName: owner.destination == .deleted ? "trash" : "doc.text").font(.system(size: 36, weight: .light)).foregroundStyle(.tertiary)
                    Text(shelfText(owner.destination == .deleted ? "Recently Deleted" : "Select a note")).font(.system(size: 13)).foregroundStyle(.secondary)
                    if owner.destination == .deleted {
                        Button(shelfText("Delete All Permanently"), role: .destructive) { owner.confirmPermanentDeletion() }
                            .disabled(owner.library.deletedEntries.isEmpty).padding(.top, 8)
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(nsColor: .controlBackgroundColor).opacity(0.94))
            }
        }.environment(\.locale, language.locale)
    }
}

private struct ShelfSidebar: View {
    @ObservedObject var owner: ShelfPreviewWindow
    @ObservedObject var collections: NoteCollections
    @State private var expanded = true
    @ObservedObject private var language = LanguageSettings.shared
    var body: some View {
        VStack(spacing: 0) {
            List(selection: Binding<ShelfDestination?>(get: { owner.destination }, set: { if let next = $0 { owner.navigate(next) } })) {
                Section {
                    row(.all, "tray.full")
                    row(.desktop, "macwindow")
                    row(.shelved, "archivebox")
                    row(.favorites, "star")
                    row(.deleted, "trash")
                }
                Section {
                    if expanded {
                        ForEach(collections.collections) { collection in
                            row(.collection(collection.id), "folder", title: collection.displayName)
                                .contextMenu {
                                    Button(shelfText("Rename Collection")) { owner.editCollection(collection.id) }
                                    Button(shelfText("Delete Collection")) { owner.removeCollection(collection.id) }
                                }
                        }
                    }
                } header: {
                    HStack {
                        Button { expanded.toggle() } label: {
                            Label(shelfText("My Collections"), systemImage: expanded ? "chevron.down" : "chevron.right")
                        }.buttonStyle(.plain)
                        Spacer()
                        Button { owner.editCollection() } label: { Image(systemName: "plus") }
                            .buttonStyle(.plain).help(shelfText("New Collection"))
                    }
                }
            }.listStyle(.sidebar).scrollContentBackground(.hidden)
                .padding(.top, 12)
            HStack {
                Label("Foldpin", systemImage: "square.stack.3d.up")
                Spacer()
            }.font(.system(size: 11, weight: .medium)).foregroundStyle(.tertiary).padding(18)
        }.frame(maxHeight: .infinity, alignment: .top)
            .environment(\.locale, language.locale)
    }
    private func row(_ destination: ShelfDestination, _ symbol: String, title: String? = nil) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 16, weight: .regular)).foregroundStyle(.primary.opacity(0.8)).frame(width: 22)
            Text(title ?? destination.label).lineLimit(1)
            Spacer(minLength: 0)
            Text(owner.count(destination).formatted()).font(.system(size: 11)).foregroundStyle(.tertiary).monospacedDigit()
        }.font(.system(size: 13)).frame(height: 30).tag(destination)
    }
}

private struct ShelfBrowser: View {
    @ObservedObject var owner: ShelfPreviewWindow
    @ObservedObject var collections: NoteCollections
    @State private var geometry = ShelfHitGeometry()
    @AppStorage("libraryGroupByDate") private var groupByDate = true
    private let types = ["All Types", "Text", "Tasks", "Code", "Images", "Audio", "Video", "Tables", "Attachments"]
    var body: some View {
        VStack(spacing: 0) {
            filters
            if let message = owner.library.message(bundle: LanguageSettings.shared.bundle) ?? collections.error?.localizedDescription {
                HStack { Text(message); Button(shelfText("Retry Load")) { owner.retry() } }
                    .font(.system(size: 11)).foregroundStyle(.red).padding(12)
            }
            if let feedback = owner.feedback {
                HStack { Text(feedback); Spacer(); Button { owner.feedback = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain) }
                    .font(.system(size: 11)).padding(10).background(.blue.opacity(0.07))
            }
            if case .collection(let id) = owner.destination, let collection = collections.collections.first(where: { $0.id == id }) {
                HStack {
                    Image(systemName: "folder").foregroundStyle(.secondary)
                    Text(collection.displayName).fontWeight(.medium)
                    Spacer()
                    Menu(shelfText("Collection Actions")) {
                        Button(shelfText("Open Entire Collection")) { owner.batch("Open on Desktop", ids: collection.members.intersection(Set(owner.summaries.filter { !$0.deleted }.map(\.id)))) }
                        Button(shelfText("Shelve Entire Collection")) { owner.batch("Shelve", ids: collection.members.intersection(Set(owner.summaries.filter { !$0.deleted }.map(\.id)))) }
                        Divider()
                        Button(shelfText("Rename Collection")) { owner.editCollection(id) }
                        Button(shelfText("Delete Collection")) { owner.removeCollection(id) }
                    }.menuStyle(.borderlessButton).fixedSize()
                }.font(.system(size: 12)).padding(.horizontal, 22).padding(.bottom, 12)
            }
            ScrollView {
                if owner.results.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: owner.query.isEmpty ? "tray" : "magnifyingglass").font(.system(size: 38, weight: .ultraLight)).foregroundStyle(.tertiary)
                        Text(shelfText(owner.query.isEmpty ? "No Notes Here" : "No Matching Notes")).font(.system(size: 16, weight: .medium))
                        Text(shelfText(owner.query.isEmpty ? "Your notes will appear here." : "Try another keyword or content type.")).foregroundStyle(.secondary).font(.system(size: 12))
                    }.frame(maxWidth: .infinity).padding(.top, 120)
                } else if owner.grid {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 270, maximum: 420), spacing: 16)], alignment: .leading, spacing: 16) {
                        ForEach(owner.sections(grouped: groupByDate)) { section in
                            Section {
                                ForEach(section.items) { item in ShelfCard(item: item, owner: owner, collections: collections, geometry: geometry).modifier(ShelfItemFrame(id: item.id, geometry: geometry)) }
                            } header: { groupHeader(section.title) }
                        }
                    }.padding(22)
                } else {
                    LazyVStack(spacing: 0) {
                        ForEach(owner.sections(grouped: groupByDate)) { section in
                            Section {
                                ForEach(section.items) { item in ShelfListRow(item: item, owner: owner, collections: collections).modifier(ShelfItemFrame(id: item.id, geometry: geometry)) }
                            } header: { groupHeader(section.title).padding(.horizontal, 8) }
                        }
                    }.padding(.horizontal, 14).padding(.vertical, 8)
                }
            }
            .coordinateSpace(name: "shelf-viewport")
            .overlay { ShelfMarqueeOverlay(owner: owner, geometry: geometry) }
            HStack {
                Text(String(format: shelfText("%lld notes"), owner.results.count))
                Spacer()
                Text(shelfText("Collect now. Find it later."))
            }.font(.system(size: 10)).foregroundStyle(.secondary).padding(.horizontal, 22).frame(height: 32)
                .overlay(alignment: .top) { Divider().opacity(0.3) }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.94))
    }
    @ViewBuilder private func groupHeader(_ title: String?) -> some View {
        if let title {
            Text(shelfText(title)).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 16).padding(.bottom, 8)
        }
    }
    private var filters: some View {
        HStack(spacing: 12) {
            Menu {
                ForEach(types, id: \.self) { type in Button(shelfText(type)) { owner.filter(type) } }
            } label: { Label(shelfText(owner.typeFilter), systemImage: "line.3.horizontal.decrease") }
                .menuStyle(.borderlessButton).fixedSize()
            Spacer(minLength: 4)
            Menu {
                ForEach(["Recently Modified", "Oldest Modified", "Recently Created", "Oldest Created"], id: \.self) { sort in
                    Button(shelfText(sort)) { owner.sort = sort }
                }
                Divider()
                Toggle(shelfText("Group by Date"), isOn: $groupByDate)
            } label: { Label(shelfText(owner.sort), systemImage: "arrow.up.arrow.down") }
                .menuStyle(.borderlessButton).fixedSize()
        }.font(.system(size: 12)).foregroundStyle(.secondary).padding(.horizontal, 22).frame(height: 52)
            .overlay(alignment: .bottom) { Divider().opacity(0.22) }
    }

}

private struct ShelfCard: View {
    @AppStorage(NoteAppearance.preferenceKey) private var appearance: NoteAppearance = .paper
    let item: ShelfSummary
    @ObservedObject var owner: ShelfPreviewWindow
    @ObservedObject var collections: NoteCollections
    let geometry: ShelfHitGeometry
    @State private var hovering = false
    private var chosen: Bool { owner.multiple ? owner.picked.contains(item.id) : owner.selectedEntry?.id == item.id }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                ShelfIcon(item: item).font(.system(size: 23)).frame(height: 29)
                Spacer()
                if !item.deleted { Text(shelfText(item.shelved ? "On Shelf" : "On Desktop")).font(.system(size: 10)).padding(.horizontal, 6).padding(.vertical, 3).background(.white.opacity(0.26), in: RoundedRectangle(cornerRadius: 5)) }
                if !owner.multiple {
                    Button { owner.favorite(item.id, !item.favorite) } label: {
                        Image(systemName: item.favorite ? "star.fill" : "star").foregroundStyle(item.favorite ? .orange : .secondary)
                    }.buttonStyle(.plain).opacity(item.favorite || hovering ? 1 : 0).disabled(item.deleted)
                        .help(shelfText(item.favorite ? "Remove Favorite" : "Favorite"))
                        .modifier(ShelfItemFrame(id: item.id, geometry: geometry, isControl: true))
                }
            }
            Text(item.displayTitle).font(.system(size: 13, weight: .semibold)).lineLimit(2)
            Text(item.excerpt(query: owner.query)).font(.system(size: 12, design: item.types.contains("Code") ? .monospaced : .default))
                .lineSpacing(4).lineLimit(4).opacity(0.72).frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 0)
            Text(item.modified, style: .date).font(.system(size: 10)).opacity(0.5)
        }.foregroundStyle(Color(nsColor: appearance.textColor))
            .padding(17).frame(maxWidth: .infinity, alignment: .leading).frame(height: 220)
            .modifier(NoteSheetSurface(appearance: appearance, cornerRadius: 13, color: item.color))
            .overlay { RoundedRectangle(cornerRadius: 13).strokeBorder(Color.primary.opacity(0.055), lineWidth: 0.75) }
            .overlay { RoundedRectangle(cornerRadius: 16).stroke(chosen ? Color.accentColor.opacity(0.75) : .clear, lineWidth: 2).padding(-4) }
            .shadow(color: .black.opacity(hovering ? 0.10 : 0.025), radius: hovering ? 10 : 2, y: hovering ? 4 : 1)
            .contentShape(RoundedRectangle(cornerRadius: 13))
            .onHover { hovering = $0 }
            .contextMenu { ShelfNoteMenu(item: item, owner: owner, collections: collections) }
            .accessibilityElement(children: .combine).accessibilityLabel(item.displayTitle)
            .accessibilityAddTraits(chosen ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction { owner.select(item.id) }
    }
}

private struct ShelfIcon: View {
    let item: ShelfSummary
    var body: some View {
        if let icon = item.icon { Text(icon) }
        else { Image(systemName: item.symbol).fontWeight(.light).opacity(0.65) }
    }
}

private struct ShelfListRow: View {
    @AppStorage(NoteAppearance.preferenceKey) private var appearance: NoteAppearance = .paper
    let item: ShelfSummary
    @ObservedObject var owner: ShelfPreviewWindow
    @ObservedObject var collections: NoteCollections
    var body: some View {
        HStack(spacing: 14) {
            ShelfIcon(item: item).font(.system(size: 19)).frame(width: 40, height: 44)
                .foregroundStyle(Color(nsColor: appearance.textColor))
                .modifier(NoteSheetSurface(appearance: appearance, cornerRadius: 8, color: item.color))
            VStack(alignment: .leading, spacing: 5) {
                Text(item.displayTitle).font(.system(size: 13, weight: .medium)).lineLimit(1)
                Text(item.excerpt(query: owner.query)).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if item.favorite { Image(systemName: "star.fill").foregroundStyle(.orange).font(.system(size: 11)) }
            VStack(alignment: .trailing, spacing: 5) {
                Text(shelfText(item.deleted ? "Recently Deleted" : item.shelved ? "On Shelf" : "On Desktop"))
                Text(item.modified, style: .date).foregroundStyle(.tertiary)
            }.font(.system(size: 10)).foregroundStyle(.secondary)
        }.padding(.horizontal, 12).frame(height: 76)
            .background((owner.multiple ? owner.picked.contains(item.id) : owner.selectedEntry?.id == item.id) ? Color.accentColor.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 8))
            .overlay(alignment: .bottom) { Divider().opacity(0.25) }
            .contentShape(Rectangle())
            .contextMenu { ShelfNoteMenu(item: item, owner: owner, collections: collections) }
            .accessibilityElement(children: .combine).accessibilityAddTraits(.isButton).accessibilityAction { owner.select(item.id) }
    }
}

private struct ShelfNoteMenu: View {
    let item: ShelfSummary
    @ObservedObject var owner: ShelfPreviewWindow
    @ObservedObject var collections: NoteCollections
    var body: some View {
        if item.deleted {
            Button(shelfText("Restore Note")) { _ = owner.restore(item.id) }
            Button(shelfText("Delete Permanently"), role: .destructive) {
                owner.confirmPermanentDeletion(ids: owner.picked.contains(item.id) ? owner.picked : [item.id])
            }
        } else {
            Button(shelfText(item.shelved ? "Open on Desktop" : "Locate Desktop Note")) { owner.open(item.id) }
            Button(shelfText("Open and Hide Library")) { owner.open(item.id, hideLibrary: true) }
            if !item.shelved { Button(shelfText("Shelve")) { _ = owner.shelve(item.id); owner.rebuild() } }
            Divider()
            Button(shelfText(item.favorite ? "Remove Favorite" : "Favorite")) { owner.favorite(item.id, !item.favorite) }
            Menu(shelfText("Collections")) {
                ForEach(collections.collections) { collection in
                    Button { owner.membership(collection.id, ids: [item.id], included: !collection.members.contains(item.id)) } label: {
                        Label(collection.displayName, systemImage: collection.members.contains(item.id) ? "checkmark" : "folder")
                    }
                }
                Button(shelfText("New Collection")) { owner.editCollection() }
            }
            Divider()
            Button(shelfText("Export Content…")) { owner.exportNotes(ids: owner.picked.contains(item.id) ? owner.picked : [item.id]) }
            Button(shelfText("Delete Note")) { _ = owner.delete(item.id) }
        }
    }
}

private struct ShelfDetail: View {
    @ObservedObject var owner: ShelfPreviewWindow
    @ObservedObject var collections: NoteCollections
    var body: some View {
        if let entry = owner.selectedEntry {
            ShelfDetailContent(owner: owner, collections: collections, store: entry.store, id: entry.id)
        }
    }
}

private struct ShelfDetailContent: View {
    @AppStorage(NoteAppearance.preferenceKey) private var appearance: NoteAppearance = .paper
    @ObservedObject var owner: ShelfPreviewWindow
    @ObservedObject var collections: NoteCollections
    @ObservedObject var store: NoteStore
    let id: UUID
    @State private var showsIcons = false
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button { showsIcons = true } label: {
                    if let icon = store.document.icon { Text(icon).font(.system(size: 24)) }
                    else { Image(systemName: "face.smiling").font(.system(size: 17)).foregroundStyle(.secondary) }
                }.buttonStyle(.plain).disabled(store.document.deletedAt != nil || store.loadError != nil)
                    .help(shelfText(store.document.icon == nil ? "Add Icon" : "Change Icon"))
                    .popover(isPresented: $showsIcons) {
                        NoteIconPicker(selectedIcon: store.document.icon, onSelect: { icon in
                            if store.setIcon(icon) { showsIcons = false }
                        }, onClose: { showsIcons = false })
                    }
                Spacer()
            }.frame(height: NoteLayout.headerHeight)
            if let error = store.loadError ?? store.saveError {
                VStack(alignment: .leading) {
                    Text(error).foregroundStyle(.red)
                    Button(shelfText(store.loadError == nil ? "Retry Save" : "Retry Load")) {
                        if store.loadError == nil {
                            if store.flush() { owner.selected?.session.librarySlot?.claimEditor() }
                        } else { store.reload() }
                    }
                }.font(.system(size: 11)).padding(12)
            }
            if store.document.deletedAt == nil, store.loadError == nil, let controller = owner.selected {
                ShelfEditorSlot(session: controller.session, store: store, appearance: appearance).id(id)
            } else { ShelfReadOnlyContent(store: store, appearance: appearance) }
            HStack(spacing: 10) {
                if store.document.deletedAt != nil {
                    Button(shelfText("Restore Note")) { _ = owner.restore(id) }
                    Spacer()
                    Button(shelfText("Delete Permanently"), role: .destructive) { owner.confirmPermanentDeletion(ids: [id]) }
                } else {
                    Button { owner.open(id) } label: { Image(systemName: "arrow.up.right.square") }
                        .buttonStyle(.plain)
                        .help(shelfText(store.document.isShelved ? "Open on Desktop" : "Locate Desktop Note"))
                    Spacer()
                    NoteActionsButton(state: owner.noteActionsState, appearance: appearance) { owner.toggleNoteActions(id) }
                }
            }.font(.system(size: 12)).padding(.horizontal, 14).padding(.vertical, 10)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
            .foregroundStyle(Color(nsColor: appearance.textColor))
            .modifier(NoteSheetSurface(appearance: appearance, cornerRadius: NoteWindowStyle.cornerRadius, color: store.document.color))
            .overlay { RoundedRectangle(cornerRadius: NoteWindowStyle.cornerRadius).strokeBorder(.primary.opacity(0.06), lineWidth: 0.75) }
            .padding(14)
    }
}

struct ShelfEditorSlot: NSViewRepresentable {
    let session: NoteEditingSession
    @ObservedObject var store: NoteStore
    var appearance: NoteAppearance
    func makeNSView(context: Context) -> NoteEditingSlot {
        let slot = NoteEditingSlot(session: session, isLibrary: true)
        session.libraryInk = appearance.textColor
        session.librarySlot = slot
        // Claiming commits IME/captions and may publish a save result. Never do
        // that inside makeNSView's SwiftUI update transaction.
        DispatchQueue.main.async { [weak slot] in
            guard let slot, slot.window != nil, session.librarySlot === slot else { return }
            slot.claimEditor()
        }
        return slot
    }
    static func dismantleNSView(_ view: NoteEditingSlot, coordinator: ()) {
        if view.session.librarySlot === view { view.session.librarySlot = nil }
    }
    func updateNSView(_ view: NoteEditingSlot, context: Context) {
        session.libraryInk = appearance.textColor
        session.scheduleContentRefresh()
        session.host.editor.isEditable = store.loadError == nil
        session.host.editor.tableCellEditor?.isEditable = store.loadError == nil
        if session.inPreview {
            session.host.updateColors(appearance.textColor)
            session.host.editor.updatePaperBackground(NotePalette.paperBackground(for: store.document.color))
        }
        view.refreshMirror()
    }
}

private struct ShelfReadOnlyContent: NSViewRepresentable {
    @ObservedObject var store: NoteStore
    var appearance: NoteAppearance
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        let text = NSTextView()
        text.isEditable = false; text.isSelectable = true
        text.drawsBackground = false; scroll.drawsBackground = false
        text.usesAdaptiveColorMappingForDarkAppearance = false
        text.autoresizingMask = [.width]; text.isVerticallyResizable = true
        text.textContainerInset = NSSize(width: 22, height: 20)
        text.textContainer?.widthTracksTextView = true
        scroll.documentView = text; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let text = scroll.documentView as? NSTextView else { return }
        let rendered = NSMutableAttributedString(attributedString: BlockTextCodec.render(store.document.content,
            color: appearance.textColor, width: max(240, scroll.bounds.width - 44), image: { image in
                NSImage(contentsOf: store.file.imageURL(image.id))
            }))
        // The derived title is display-only; never introduce a required title field.
        if store.document.content.blocks.first?.kind == .paragraph,
           let firstLine = rendered.string.split(separator: "\n", omittingEmptySubsequences: false).first, !firstLine.isEmpty {
            rendered.addAttribute(.font, value: NSFont.systemFont(ofSize: 18, weight: .semibold),
                                  range: NSRange(location: 0, length: (String(firstLine) as NSString).length))
        }
        text.textStorage?.setAttributedString(rendered)
    }
}

/// Hit-test geometry is native input data, not SwiftUI layout state. Keeping it
/// outside the observation graph prevents measurement → body → measurement loops.
@MainActor
private final class ShelfHitGeometry {
    private var items: [UUID: CGRect] = [:]
    private var controls: [UUID: CGRect] = [:]
    private var itemSources: [UUID: UUID] = [:]
    private var controlSources: [UUID: UUID] = [:]
    weak var view: ShelfMarqueeView?
    func attach(_ view: ShelfMarqueeView) {
        self.view = view
        view.itemFrames = items
        view.controlFrames = Array(controls.values)
    }
    func set(_ id: UUID, source: UUID, frame: CGRect?, isControl: Bool) {
        // A grid/list replacement may appear before the old view disappears.
        // Only the measuring view that owns a frame may remove it.
        if isControl {
            guard frame != nil || controlSources[id] == source else { return }
            controlSources[id] = frame == nil ? nil : source
            guard controls[id] != frame else { return }
            controls[id] = frame
            view?.controlFrames = Array(controls.values)
        } else {
            guard frame != nil || itemSources[id] == source else { return }
            itemSources[id] = frame == nil ? nil : source
            guard items[id] != frame else { return }
            items[id] = frame
            view?.itemFrames = items
        }
    }
}
private struct ShelfItemFrame: ViewModifier {
    let id: UUID
    let geometry: ShelfHitGeometry
    var isControl = false
    @State private var source = UUID()
    func body(content: Content) -> some View {
        content.background {
            GeometryReader { proxy in
                Color.clear
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("shelf-viewport")) } action: {
                        geometry.set(id, source: source, frame: $0, isControl: isControl)
                    }
                    .onAppear {
                        geometry.set(id, source: source, frame: proxy.frame(in: .named("shelf-viewport")), isControl: isControl)
                    }
                    .onDisappear { geometry.set(id, source: source, frame: nil, isControl: isControl) }
            }
        }
    }
}
private struct ShelfMarqueeOverlay: NSViewRepresentable {
    let owner: ShelfPreviewWindow
    let geometry: ShelfHitGeometry
    func makeNSView(context: Context) -> ShelfMarqueeView {
        let view = ShelfMarqueeView(owner: owner)
        geometry.attach(view)
        return view
    }
    func updateNSView(_ view: ShelfMarqueeView, context: Context) {}
}

/// Select on the first native press, open on the second press. Do not make
/// single selection wait for a double-click recognizer. Controls pass through.
@MainActor
final class ShelfMarqueeView: NSView {
    weak var owner: ShelfPreviewWindow?
    var itemFrames: [UUID: CGRect] = [:] {
        didSet {
            guard itemFrames != oldValue, active else { return }
            rememberFrames()
            // Geometry arrives during layout. Merge it now, publish selection
            // after the update; native mouse events still select synchronously.
            scheduleGeometrySelection()
        }
    }
    private var geometrySelectionPending = false
    private var dragGeneration = 0
    private func scheduleGeometrySelection() {
        guard !geometrySelectionPending else { return }
        geometrySelectionPending = true
        let generation = dragGeneration
        DispatchQueue.main.async { [weak self] in
            guard let self, dragGeneration == generation else { return }
            geometrySelectionPending = false
            updateSelection()
        }
    }
    var controlFrames: [CGRect] = []
    private var documentFrames: [UUID: CGRect] = [:]
    private var start: NSPoint?
    private var end: NSPoint?
    private var baseline: Set<UUID> = []
    private var modifiers: NSEvent.ModifierFlags = []
    private var active = false
    private var scrollTimer: Timer?
    private weak var viewportScroll: NSScrollView?
    init(owner: ShelfPreviewWindow) { self.owner = owner; super.init(frame: .zero) }
    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard bounds.contains(local), local.x < bounds.maxX - 16 else { return nil }
        if itemFrames.values.contains(where: { $0.contains(local) }) {
            guard let event = NSApp.currentEvent, capturesItemPress(at: local, event: event) else { return nil }
        }
        return self
    }
    func capturesItemPress(at point: NSPoint, event: NSEvent) -> Bool {
        guard event.type == .leftMouseDown, !event.modifierFlags.contains(.control) else { return false }
        let modified = !event.modifierFlags.intersection([.command, .shift]).isEmpty
        return modified || !controlFrames.contains { $0.contains(point) }
    }
    override func mouseDown(with event: NSEvent) {
        guard let owner else { return }
        let point = convert(event.locationInWindow, from: nil)
        if capturesItemPress(at: point, event: event),
           let id = itemFrames.first(where: { $0.value.contains(point) })?.key {
            reset()
            // Bypass the card's single/double-click recognizers. Capture flags
            // now so releasing Command/Shift cannot change the selection action.
            let modified = !event.modifierFlags.intersection([.command, .shift]).isEmpty
            if !modified, event.clickCount == 2 {
                if !owner.multiple, owner.results.contains(where: { $0.id == id && !$0.deleted }) { owner.open(id) }
            } else {
                owner.select(id, modifiers: event.modifierFlags)
                window?.makeFirstResponder(self)
            }
            return
        }
        window?.makeFirstResponder(self)
        start = point; end = start
        modifiers = event.modifierFlags
        baseline = owner.multiple ? owner.picked : Set(owner.selectedEntry.map { [$0.id] } ?? [])
        viewportScroll = findViewportScroll()
        documentFrames = [:]; rememberFrames()
    }
    override func mouseDragged(with event: NSEvent) {
        guard let start, let owner else { return }
        end = convert(event.locationInWindow, from: nil)
        guard let end else { return }
        if !active {
            guard hypot(end.x - start.x, end.y - start.y) >= 4 else { return }
            guard owner.beginMarquee() else { self.start = nil; self.end = nil; return }
            active = true
            scrollTimer = Timer.scheduledTimer(withTimeInterval: 0.04, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.scrollAtEdge() }
            }
        }
        updateSelection()
    }
    private func updateSelection() {
        guard active, let start, let end, let owner else { return }
        let offset = viewportScroll?.contentView.bounds.minY ?? 0
        let rect = NSRect(x: min(start.x, end.x), y: min(start.y, end.y) + offset,
                          width: abs(end.x - start.x), height: abs(end.y - start.y))
        let hits = Set(documentFrames.compactMap { rect.intersects($0.value) ? $0.key : nil })
        owner.applyMarquee(hits, base: baseline, modifiers: modifiers)
        needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) {
        if active { rememberFrames(); updateSelection() }
        let completed = active
        let clear = start != nil && modifiers.intersection([.command, .shift]).isEmpty
        // Stop consuming frame updates before revealing the inspector changes
        // the grid's column count. The finished selection must stay fixed.
        reset()
        if completed { owner?.endMarquee() }
        else if clear { owner?.closePreview() }
    }
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil, active {
            reset()
            DispatchQueue.main.async { [weak self, weak owner] in
                guard self?.window == nil, owner?.marqueeActive == true else { return }
                owner?.endMarquee()
            }
        }
        super.viewWillMove(toWindow: newWindow)
    }
    private func reset() { dragGeneration += 1; geometrySelectionPending = false; scrollTimer?.invalidate(); scrollTimer = nil; start = nil; end = nil; active = false; needsDisplay = true }
    private func rememberFrames() {
        let offset = viewportScroll?.contentView.bounds.minY ?? 0
        for (id, rect) in itemFrames { documentFrames[id] = rect.offsetBy(dx: 0, dy: offset) }
    }
    private func findViewportScroll() -> NSScrollView? {
        guard let root = window?.contentView else { return nil }
        let target = convert(bounds, to: nil)
        func find(_ view: NSView) -> NSScrollView? {
            if let scroll = view as? NSScrollView {
                let rect = scroll.convert(scroll.bounds, to: nil)
                if abs(rect.width - target.width) < 2 && abs(rect.height - target.height) < 2 && abs(rect.minY - target.minY) < 2 { return scroll }
            }
            return view.subviews.compactMap(find).first
        }
        return find(root)
    }
    override func scrollWheel(with event: NSEvent) { (viewportScroll ?? findViewportScroll())?.scrollWheel(with: event) }
    private func scrollAtEdge() {
        guard active, let end, let scroll = viewportScroll, let document = scroll.documentView else { return }
        let step: CGFloat = end.y > bounds.maxY - 24 ? 14 : end.y < 24 ? -14 : 0
        guard step != 0 else { return }
        let clip = scroll.contentView
        let old = clip.bounds.origin
        let y = max(0, min(document.bounds.height - clip.bounds.height, old.y + step))
        guard y != old.y else { return }
        clip.scroll(to: NSPoint(x: old.x, y: y)); scroll.reflectScrolledClipView(clip)
        start?.y -= y - old.y
        DispatchQueue.main.async { [weak self] in self?.updateSelection() }
    }
    private func selectionRect(start: NSPoint, end: NSPoint) -> NSRect {
        NSRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y)).intersection(bounds)
    }
    override func draw(_ dirtyRect: NSRect) {
        guard active, let start, let end else { return }
        let path = NSBezierPath(rect: selectionRect(start: start, end: end))
        NSColor.controlAccentColor.withAlphaComponent(0.12).setFill(); path.fill()
        NSColor.controlAccentColor.withAlphaComponent(0.8).setStroke(); path.lineWidth = 1; path.stroke()
    }
}

private struct ShelfSelectionSummary: View {
    @ObservedObject var owner: ShelfPreviewWindow
    @ObservedObject var collections: NoteCollections
    private var items: [ShelfSummary] { owner.selectedSummaries }
    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    ZStack {
                        ForEach(Array(items.prefix(3).enumerated()), id: \.element.id) { index, item in
                            RoundedRectangle(cornerRadius: 16)
                                .fill(Color(nsColor: NotePalette.paperBackground(for: item.color)))
                                .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(.primary.opacity(0.08)) }
                                .overlay { ShelfIcon(item: item).font(.system(size: 54)).foregroundStyle(Color(nsColor: NotePalette.paperText)) }
                                .frame(width: 150, height: 180)
                                .rotationEffect(.degrees(Double(index - 1) * 7))
                                .offset(x: CGFloat(index - 1) * 17, y: CGFloat(index) * -8)
                                .shadow(color: .black.opacity(0.09), radius: 8, y: 5)
                        }
                    }.frame(maxWidth: .infinity).frame(height: 270).padding(.top, 22).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(String(format: shelfText("%lld notes"), items.count)).font(.system(size: 19, weight: .semibold))
                        Text(statusSummary).font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        Text(shelfText("Information")).font(.system(size: 13, weight: .semibold))
                        info("Created", dates(items.map(\.created)))
                        Divider().opacity(0.4)
                        info("Modified", dates(items.map(\.modified)))
                        Divider().opacity(0.4)
                        info("Favorites", String(items.filter(\.favorite).count))
                    }
                }.padding(.horizontal, 20).padding(.bottom, 24)
            }
            Menu {
                if owner.destination == .deleted {
                    Button(shelfText("Restore Note")) { owner.batch("Restore Note") }
                    Button(shelfText("Delete Permanently"), role: .destructive) { owner.confirmPermanentDeletion(ids: owner.picked) }
                }
                else {
                    Button(shelfText("Open on Desktop")) { owner.batch("Open on Desktop") }
                    Button(shelfText("Shelve")) { owner.batch("Shelve") }
                    Button(shelfText("Favorite")) { for id in owner.picked { owner.favorite(id, true) } }
                    Menu(shelfText("Add to Collection")) {
                        ForEach(collections.collections) { collection in
                            Button(collection.displayName) { owner.membership(collection.id, ids: owner.picked, included: true) }
                        }
                    }
                    Divider()
                    Button(shelfText("Export Content…")) { owner.exportNotes(ids: owner.picked) }
                    Button(shelfText("Delete Note")) { owner.batch("Delete Note") }
                }
            } label: {
                VStack(spacing: 7) { Image(systemName: "ellipsis.circle").font(.system(size: 18)); Text(shelfText("More")).font(.system(size: 11)) }
                    .frame(maxWidth: .infinity)
            }.menuStyle(.borderlessButton).fixedSize().padding(.bottom, 22)
        }.background(Color(nsColor: .controlBackgroundColor).opacity(0.94))
    }
    private var statusSummary: String {
        if owner.destination == .deleted { return shelfText("Recently Deleted") }
        return "\(shelfText("On Desktop")) \(items.filter { !$0.shelved }.count) · \(shelfText("On Shelf")) \(items.filter(\.shelved).count)"
    }
    private func dates(_ values: [Date]) -> String {
        guard let first = values.min(), let last = values.max() else { return "—" }
        let formatter = DateFormatter(); formatter.locale = LanguageSettings.shared.locale; formatter.dateStyle = .medium
        let a = formatter.string(from: first), b = formatter.string(from: last)
        return a == b ? a : a + " – " + b
    }
    private func info(_ key: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(shelfText(key)).foregroundStyle(.secondary)
            Spacer(minLength: 10)
            Text(value).multilineTextAlignment(.trailing)
        }.font(.system(size: 11))
    }
}

private extension LibraryCollection {
    var displayName: String { conflictOf == nil ? name : shelfText("Conflict copy") + " · " + name }
}
