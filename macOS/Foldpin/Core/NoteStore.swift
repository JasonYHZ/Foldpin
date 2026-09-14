import Combine
import Foundation
import CoreGraphics

@MainActor
final class NoteStore: ObservableObject {
    @Published private(set) var document = NoteDocument()
    @Published private(set) var isDirty = false
    @Published private var saveFailure: Error?
    @Published private var loadFailure: Error?
    @Published var localizationBundle: Bundle
    @Published var hotKeyStatus: Int32 = 0
    @Published var shortcutLabel = "⌃⌥Space"
    @Published var focusRequest = 0

    let file: NoteFile
    private var pendingSave: Task<Void, Never>?
    private var permanentlyDeleted = false

    init(file: NoteFile? = nil, localizationBundle: Bundle = .main) {
        self.localizationBundle = localizationBundle
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        self.file = file ?? NoteFile(url: base.appendingPathComponent("Foldpin", isDirectory: true).appendingPathComponent("note.json"))
        reload()
    }

    func reload() {
        guard !permanentlyDeleted else { return }
        pendingSave?.cancel()
        do {
            document = try file.load()
            loadFailure = nil; saveFailure = nil; isDirty = false
        } catch {
            // Do not replace an unreadable file with an empty draft or autosave over it.
            loadFailure = error
        }
    }

    func edit(_ text: String) {
        guard loadError == nil, text != document.text else { return }
        edit(NoteContent(plainText: text))
    }

    func edit(_ content: NoteContent) {
        guard loadError == nil, content != document.content else { return }
        document.content = content
        document.modifiedAt = Date()
        scheduleSave()
    }

    @discardableResult func setFavorite(_ value: Bool) -> Bool {
        guard loadError == nil else { return false }
        let previous = document.isFavorite
        document.isFavorite = value
        isDirty = true
        if flush() { return true }
        document.isFavorite = previous
        return false
    }

    /// Restoring from the library always returns to the shelf, in one save.
    @discardableResult func restoreToShelf() -> Bool {
        guard loadError == nil else { return false }
        let deleted = document.deletedAt
        let shelved = document.isShelved
        document.deletedAt = nil
        document.isShelved = true
        isDirty = true
        if flush() { return true }
        document.deletedAt = deleted
        document.isShelved = shelved
        return false
    }

    func setPinned(_ value: Bool) {
        guard loadError == nil, document.isPinned != value else { return }
        document.isPinned = value
        scheduleSave()
    }

    func setColor(_ value: NoteColor) {
        guard loadError == nil, document.color != value else { return }
        document.color = value
        scheduleSave()
    }

    @discardableResult func setIcon(_ value: String?) -> Bool {
        guard loadError == nil else { return false }
        let icon: String?
        if let value {
            guard let normalized = NoteIcon.normalized(value) else { return false }
            icon = normalized
        } else { icon = nil }
        guard document.icon != icon else { return true }
        document.icon = icon
        scheduleSave()
        return true
    }

    func setShelved(_ value: Bool) {
        guard loadError == nil, document.isShelved != value else { return }
        document.isShelved = value
        scheduleSave()
    }

    /// Commit the lifecycle transition before removing the visible entry.
    /// On failure keep both the original state and the unsaved content visible.
    @discardableResult func setDeletedAt(_ date: Date?) -> Bool {
        guard loadError == nil else { return false }
        let previous = document.deletedAt
        document.deletedAt = date
        isDirty = true
        if flush() { return true }
        document.deletedAt = previous
        return false
    }

    func setFrame(_ frame: CGRect) {
        guard loadError == nil, document.frame != NoteFrame(frame) else { return }
        document.frame = NoteFrame(frame)
        scheduleSave()
    }

    var isCollapsed: Bool { document.isCollapsed && loadError == nil }

    func setCollapsed(_ value: Bool) {
        guard loadError == nil, document.isCollapsed != value else { return }
        document.isCollapsed = value
        scheduleSave()
    }

    func recordWindowFrame(_ frame: CGRect, collapsed: Bool) {
        setFrame(NoteLayout.expandedFrame(window: frame, collapsed: collapsed,
                                          rememberedHeight: document.frame?.height ?? 340))
    }

    /// Commit a desktop move before changing the visible window. Failed writes
    /// retain the previous geometry, content, and the original error for retry.
    @discardableResult func saveArrangedWindowFrame(_ frame: CGRect, collapsed: Bool) -> Bool {
        guard loadError == nil, !document.isShelved, document.deletedAt == nil,
              NoteFrame(frame).isValid else { return false }
        let previous = document.frame
        recordWindowFrame(frame, collapsed: collapsed)
        if flush() { return true }
        document.frame = previous
        return false
    }

    private func scheduleSave() {
        isDirty = true
        pendingSave?.cancel()
        pendingSave = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(450)) } catch { return }
            self?.flush()
        }
    }

    /// Terminal lifecycle state: a retained callback or undo object must never
    /// recreate a note after the user has permanently deleted it.
    func invalidateAfterPermanentDeletion() {
        permanentlyDeleted = true
        pendingSave?.cancel(); pendingSave = nil
        loadFailure = CocoaError(.fileNoSuchFile)
        saveFailure = nil; isDirty = false
        document.content = NoteContent()
    }

    @discardableResult func flush() -> Bool {
        pendingSave?.cancel(); pendingSave = nil
        guard loadError == nil else { return false }
        guard isDirty else { return saveError == nil }
        do {
            try file.save(document)
            isDirty = false; saveFailure = nil
            return true
        } catch {
            saveFailure = error
            return false
        }
    }

    // Retain the failure itself so an already-visible message can be translated
    // again without retrying disk I/O or replacing unsaved text.
    var loadError: String? {
        guard let loadFailure else { return nil }
        return String(localized: "Could not read the existing note. The original file is unchanged.\n\(description(of: loadFailure))", bundle: localizationBundle)
    }

    var saveError: String? {
        guard let saveFailure else { return nil }
        return String(localized: "Not saved: \(description(of: saveFailure))", bundle: localizationBundle)
    }

    var hotKeyWarning: String? {
        guard hotKeyStatus != 0 else { return nil }
        // An OSStatus is an identifier, not a quantity to group for the locale.
        let code = String(hotKeyStatus)
        return String(localized: "Could not register the shortcut (\(code)). Choose another in Settings → Shortcuts.", bundle: localizationBundle)
    }

    private func description(of error: Error) -> String {
        (error as? NoteFileError)?.description(bundle: localizationBundle) ?? error.localizedDescription
    }

    var status: String {
        if loadError != nil { return String(localized: "Could not load", bundle: localizationBundle) }
        if saveError != nil { return String(localized: "Not saved", bundle: localizationBundle) }
        if isDirty { return String(localized: "Saving…", bundle: localizationBundle) }
        return document.text.isEmpty ? String(localized: "Saves as you type", bundle: localizationBundle) : String(localized: "Saved on this Mac", bundle: localizationBundle)
    }
}
