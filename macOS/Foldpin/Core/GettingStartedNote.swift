import Foundation

/// First launch creates a normal document, not a separate onboarding window.
@MainActor
final class GettingStartedNote {
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    var completed: Bool { defaults.bool(forKey: "gettingStarted.completed") }
    private var noteID: UUID {
        if let value = defaults.string(forKey: "gettingStarted.sampleID"), let id = UUID(uuidString: value) { return id }
        let id = UUID(); defaults.set(id.uuidString, forKey: "gettingStarted.sampleID"); return id
    }
    func createOnFirstLaunch(in library: NoteLibrary, eligible: Bool, bundle: Bundle, shortcuts: ShortcutSettings) throws -> NoteLibrary.Entry? {
        guard eligible, !completed, library.canCreate else { return nil }
        guard library.entries.isEmpty, library.deletedEntries.isEmpty, library.path.snapshot.notes.isEmpty else {
            // Existing content includes a guide saved just before an interrupted launch.
            defaults.set(true, forKey: "gettingStarted.completed")
            return nil
        }
        return try open(in: library, bundle: bundle, shortcuts: shortcuts)
    }
    func open(in library: NoteLibrary, bundle: Bundle, shortcuts: ShortcutSettings) throws -> NoteLibrary.Entry {
        var document = NoteDocument(); document.id = noteID
        if let existing = (library.entries + library.deletedEntries).first(where: { $0.id == document.id }) {
            defaults.set(true, forKey: "gettingStarted.completed")
            return existing
        }
        // An explicit Help action can create a new guide after permanent deletion;
        // never overwrite or resurrect a tombstoned document UUID.
        if completed || library.path.snapshot.notes[document.id] != nil {
            document.id = UUID(); defaults.set(document.id.uuidString, forKey: "gettingStarted.sampleID")
        }
        document.content = Self.content(bundle: bundle, shortcuts: shortcuts)
        document.icon = "📖"
        let entry = try library.importDocument(document)
        defaults.set(true, forKey: "gettingStarted.completed")
        return entry
    }
    static func content(bundle: Bundle, shortcuts: ShortcutSettings) -> NoteContent {
        func t(_ key: String) -> String { bundle.localizedString(forKey: key, value: key, table: nil) }
        let bindings = [NoteAction.newNote, .actions].map { action in
            let binding = shortcuts.binding(action)
            let value = binding.code == nil ? t("Configure in Settings") : binding.keycaps.joined()
            return action.title(bundle: bundle) + " " + value
        }.joined(separator: "  ·  ")
        return NoteContent(blocks: [
            NoteBlock(kind: .heading, text: t("Foldpin · User Guide")),
            NoteBlock(text: t("Capture a thought. Keep it beside you. Collect it for later.")),
            NoteBlock(kind: .bullet, text: t("Write — Click and type; changes save automatically.")),
            NoteBlock(kind: .bullet, text: t("Add — Type / for headings, checklists and recording. Paste images or files directly.")),
            NoteBlock(kind: .bullet, text: t("Keep nearby — Drag the top to move, an edge to resize. Use the pin to stay on top or the arrow to fold.")),
            NoteBlock(kind: .bullet, text: t("Find later — Collect from the top right. Open Shelf from the menu bar to search and edit.")),
            NoteBlock(kind: .bullet, text: t("More — Use Actions below for colors, export and deletion. Appearance and shortcuts are in Settings.")),
            NoteBlock(kind: .task, text: t("Try checking this item.")),
            NoteBlock(text: bindings),
            NoteBlock(text: t("This note is yours to edit, collect or delete.")),
        ])
    }
}
