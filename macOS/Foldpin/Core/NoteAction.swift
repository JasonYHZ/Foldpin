import AppKit

/// Paper/app commands only. Editor commands keep their own responder chain.
nonisolated enum NoteAction: String, CaseIterable, Identifiable {
    case actions, pin, collapse, shelve, icon, color, copyAll, duplicateNote, deleteNote
    case original, yellow, green, blue, pink, purple
    case newNote, shelf, arrange, undoArrangement, shelveAll, settings, captureShortcut
    var id: String { rawValue }

    var key: String {
        switch self {
        case .actions: "k"
        case .pin: "p"
        case .collapse: "m"
        case .shelve: "w"
        case .icon: "i"
        case .copyAll: "c"
        case .original: "1"
        case .yellow: "2"
        case .green: "3"
        case .blue: "4"
        case .pink: "5"
        case .purple: "6"
        case .newNote: "n"
        case .shelf: "o"
        case .settings: ","
        case .color, .duplicateNote, .deleteNote, .arrange, .undoArrangement, .shelveAll, .captureShortcut: ""
        }
    }
    var usesShift: Bool { [.pin, .icon, .copyAll, .shelf].contains(self) }
    var modifiers: NSEvent.ModifierFlags { usesShift ? [.command, .shift] : [.command] }
    var keycaps: [String] { key.isEmpty ? [] : (usesShift ? ["⇧", "⌘"] : ["⌘"]) + [key.uppercased()] }
    var heldHint: String { (usesShift ? "⇧" : "") + key.uppercased() }
    var isPaperAction: Bool { [.pin, .collapse, .shelve, .icon, .color, .copyAll, .duplicateNote, .deleteNote].contains(self) || noteColor != nil }
    var noteColor: NoteColor? {
        switch self {
        case .original: .original
        case .yellow: .yellow
        case .green: .green
        case .blue: .blue
        case .pink: .pink
        case .purple: .purple
        default: nil
        }
    }
    static let colors: [Self] = [.original, .yellow, .green, .blue, .pink, .purple]

    static func matching(key: String?, modifiers: NSEvent.ModifierFlags) -> NoteAction? {
        guard let key, !key.isEmpty else { return nil }
        let modifiers = modifiers.intersection([.command, .shift, .control, .option])
        return allCases.first { !$0.key.isEmpty && $0.key == key.lowercased() && $0.modifiers == modifiers }
    }

    var symbol: String {
        switch self {
        case .actions: "command"
        case .pin: "pin"
        case .collapse: "chevron.up"
        case .shelve: "tray.and.arrow.down"
        case .icon: "face.smiling"
        case .color: "paintpalette"
        case .copyAll: "doc.on.doc"
        case .duplicateNote: "plus.square.on.square"
        case .deleteNote: "trash"
        case .original, .yellow, .green, .blue, .pink, .purple: "circle.fill"
        case .newNote: "square.and.pencil"
        case .shelf: "tray.full"
        case .arrange: "rectangle.3.group"
        case .undoArrangement: "arrow.uturn.backward"
        case .shelveAll: "square.stack.3d.down.right"
        case .settings: "gearshape"
        case .captureShortcut: "keyboard"
        }
    }
    func title(bundle: Bundle, pinned: Bool = false, collapsed: Bool = false, hasIcon: Bool = false) -> String {
        switch self {
        case .actions: String(localized: "Actions", bundle: bundle)
        case .pin: pinned ? String(localized: "Unpin Note", bundle: bundle) : String(localized: "Pin Note", bundle: bundle)
        case .collapse: collapsed ? String(localized: "Expand Note", bundle: bundle) : String(localized: "Collapse Note", bundle: bundle)
        case .shelve: String(localized: "Shelve Note", bundle: bundle)
        case .icon: hasIcon ? String(localized: "Change Icon", bundle: bundle) : String(localized: "Add Icon", bundle: bundle)
        case .color: String(localized: "Note Color", bundle: bundle)
        case .copyAll: String(localized: "Copy All Content", bundle: bundle)
        case .duplicateNote: String(localized: "Duplicate Note", bundle: bundle)
        case .deleteNote: String(localized: "Delete Note", bundle: bundle)
        case .original, .yellow, .green, .blue, .pink, .purple: noteColor!.title(bundle: bundle)
        case .newNote: String(localized: "New Note", bundle: bundle)
        case .shelf: String(localized: "Open Shelf", bundle: bundle)
        case .arrange: String(localized: "Arrange Desktop Notes", bundle: bundle)
        case .undoArrangement: String(localized: "Undo Arrangement", bundle: bundle)
        case .shelveAll: String(localized: "Shelve All Notes", bundle: bundle)
        case .settings: String(localized: "Settings…", bundle: bundle)
        case .captureShortcut: String(localized: "Show / Shelve Shortcut", bundle: bundle)
        }
    }
}
