import AppKit
import Carbon
import Combine

@MainActor
final class ShortcutSettings: ObservableObject {
    static let shared = ShortcutSettings()
    static let preferenceKey = "customShortcuts.v1"
    static let changed = Notification.Name("Foldpin.ShortcutsChanged")
    @Published private(set) var overrides: [String: ShortcutBinding]
    @Published var error: String?
    @Published var globalError: String?
    @Published var showShortcuts = false
    var recordingHandler: ((ShortcutBinding) -> Void)?
    var applyGlobals: (([GlobalShortcutAction: ShortcutBinding]) -> Int32)?
    var systemConflict: @MainActor (ShortcutBinding) -> Bool = ShortcutSettings.isSystemShortcut
    private let defaults: UserDefaults
    static let appActions: [NoteAction] = [.newNote, .shelf, .arrange, .undoArrangement, .shelveAll]
    static let paperActions: [NoteAction] = [.actions, .pin, .collapse, .icon, .color, .copyAll, .duplicateNote] + NoteAction.colors
    static var noteActions: [NoteAction] { appActions + paperActions }
    static var localIDs: [String] { noteActions.map { "note." + $0.rawValue } + EditorShortcutAction.allCases.map(\.id) }
    static var allIDs: [String] { localIDs + GlobalShortcutAction.allCases.map(\.id) }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        overrides = defaults.data(forKey: Self.preferenceKey)
            .flatMap { try? JSONDecoder().decode([String: ShortcutBinding].self, from: $0) } ?? [:]
        overrides = overrides.filter { Self.allIDs.contains($0.key) && $0.value.isValid }
        // Keep existing choices when introducing defaults, including the legacy
        // toggle on N. Never give an already assigned combination a second action.
        let migrationKey = "globalShortcutDefaults.v1"
        if !defaults.bool(forKey: migrationKey) {
            let toggleID = GlobalShortcutAction.toggleNotes.id
            if overrides[toggleID] == nil, defaults.integer(forKey: "captureShortcut") == 1 {
                overrides[toggleID] = .named("n", [.control, .option])
            }
            for action in GlobalShortcutAction.allCases where overrides[action.id] == nil {
                let value = defaultBinding(action.id)
                if overrides.values.contains(value) { overrides[action.id] = .disabled }
            }
            if let data = try? JSONEncoder().encode(overrides) {
                defaults.set(data, forKey: Self.preferenceKey)
                defaults.set(true, forKey: migrationKey)
            }
        }
        let findMigrationKey = "noteSearchShortcuts.v1"
        if !defaults.bool(forKey: findMigrationKey) {
            for action in EditorShortcutAction.allCases where action.isSearch && overrides[action.id] == nil {
                if overrides.values.contains(action.defaultBinding) { overrides[action.id] = .disabled }
            }
            if let data = try? JSONEncoder().encode(overrides) {
                defaults.set(data, forKey: Self.preferenceKey)
                defaults.set(true, forKey: findMigrationKey)
            }
        }
    }
    func defaultBinding(_ id: String) -> ShortcutBinding {
        if let action = GlobalShortcutAction.allCases.first(where: { $0.id == id }) {
            let key: String
            switch action {
            case .newNote: key = "n"
            case .quickRecord: key = "r"
            case .toggleNotes: key = " "
            case .shelf: key = "o"
            }
            return .named(key, [.control, .option])
        }
        if let action = NoteAction(rawValue: String(id.dropFirst(5))), id.hasPrefix("note.") {
            return .named(action.key, action.modifiers)
        }
        if let action = EditorShortcutAction(rawValue: String(id.dropFirst(7))), id.hasPrefix("editor.") { return action.defaultBinding }
        return .disabled
    }
    func binding(_ id: String) -> ShortcutBinding { overrides[id] ?? defaultBinding(id) }
    func binding(_ action: NoteAction) -> ShortcutBinding { binding("note." + action.rawValue) }
    func binding(_ action: EditorShortcutAction) -> ShortcutBinding { binding(action.id) }
    func binding(_ action: GlobalShortcutAction) -> ShortcutBinding { binding(action.id) }
    func title(_ id: String) -> String {
        let bundle = LanguageSettings.shared.bundle
        if let action = GlobalShortcutAction.allCases.first(where: { $0.id == id }) { return action.title(bundle: bundle) }
        if let action = EditorShortcutAction.allCases.first(where: { $0.id == id }) { return action.title(bundle: bundle) }
        return NoteAction(rawValue: String(id.dropFirst(5)))?.title(bundle: bundle) ?? id
    }
    func matchingNote(_ event: NSEvent) -> NoteAction? {
        guard recordingHandler == nil else { return nil }
        return (Self.noteActions + [.shelve, .settings]).first { binding($0).matches(event) }
    }
    func matchingEditor(_ event: NSEvent) -> EditorShortcutAction? {
        guard recordingHandler == nil else { return nil }
        return EditorShortcutAction.allCases.first { binding($0).matches(event) }
    }
    @discardableResult func set(_ binding: ShortcutBinding, for id: String) -> Bool {
        guard Self.allIDs.contains(id) else { return false }
        var candidate = overrides; candidate[id] = binding
        return commit(candidate)
    }
    @discardableResult func reset(_ ids: [String]) -> Bool {
        var candidate = overrides
        for id in ids { candidate.removeValue(forKey: id) }
        return commit(candidate)
    }
    private func commit(_ candidate: [String: ShortcutBinding]) -> Bool {
        let bundle = LanguageSettings.shared.bundle
        func resolved(_ id: String) -> ShortcutBinding { candidate[id] ?? defaultBinding(id) }
        var seen: [ShortcutBinding: String] = [:]
        for id in Self.allIDs {
            let value = resolved(id)
            guard value.isValid else { error = String(localized: "Use Command or Control with a letter, number, arrow, or punctuation key.", bundle: bundle); return false }
            guard value.code != nil else { continue }
            if let previous = seen[value] {
                error = String(localized: "Already assigned to \(title(previous)).", bundle: bundle); return false
            }
            seen[value] = id
            if Self.isReserved(value) || (value != binding(id) && systemConflict(value)) {
                error = String(localized: "This shortcut is reserved by macOS or standard editing. Choose another combination.", bundle: bundle); return false
            }
        }
        let globals = Dictionary(uniqueKeysWithValues: GlobalShortcutAction.allCases.map { ($0, resolved($0.id)) })
        if let applyGlobals {
            let status = applyGlobals(globals)
            guard status == 0 else {
                error = String(localized: "Could not register this global shortcut (\(String(status))). Your previous shortcuts are unchanged.", bundle: bundle); return false
            }
        }
        guard let data = try? JSONEncoder().encode(candidate) else { return false }
        defaults.set(data, forKey: Self.preferenceKey)
        overrides = candidate; error = nil
        if applyGlobals != nil { globalError = nil }
        NotificationCenter.default.post(name: Self.changed, object: self)
        return true
    }
    func registerGlobals() {
        guard let applyGlobals else { return }
        let values = Dictionary(uniqueKeysWithValues: GlobalShortcutAction.allCases.map { ($0, binding($0)) })
        let status = applyGlobals(values)
        globalError = status == 0 ? nil : String(localized: "Global shortcuts could not be registered (\(String(status))). Choose another combination or retry.", bundle: LanguageSettings.shared.bundle)
    }
    static func isReserved(_ value: ShortcutBinding) -> Bool {
        let modifiers = value.modifiers, key = value.key
        if modifiers == .command && ["a","c","v","x","z","q","w","h",",","b","i"," "].contains(key) { return true }
        if modifiers == [.command, .shift] && ["z","3","4","5","v"].contains(key) { return true }
        if modifiers == [.command, .option, .shift] && key == "v" { return true }
        if modifiers == [.control] && key == " " { return true }
        if modifiers == [.control, .command] && key == " " { return true }
        if (modifiers == .command || modifiers == [.command, .shift]) && [123,124,125,126].contains(value.code ?? 999) { return true }
        return false
    }
    static func isSystemShortcut(_ value: ShortcutBinding) -> Bool {
        var unmanaged: Unmanaged<CFArray>?
        guard CopySymbolicHotKeys(&unmanaged) == noErr,
              let values = unmanaged?.takeRetainedValue() as? [[String: Any]] else { return false }
        return values.contains {
            ($0[kHISymbolicHotKeyEnabled as String] as? NSNumber)?.boolValue == true
                && ($0[kHISymbolicHotKeyCode as String] as? NSNumber)?.uint16Value == value.code
                && ($0[kHISymbolicHotKeyModifiers as String] as? NSNumber)?.uint32Value == value.carbonModifiers
        }
    }
}

extension NoteAction {
    @MainActor var activeBinding: ShortcutBinding { ShortcutSettings.shared.binding(self) }
    @MainActor var activeKey: String { activeBinding.key }
    @MainActor var activeModifiers: NSEvent.ModifierFlags { activeBinding.modifiers }
    @MainActor var activeKeycaps: [String] { activeBinding.keycaps }
    @MainActor var activeHeldHint: String { activeKeycaps.filter { $0 != "⌘" }.joined() }
}
