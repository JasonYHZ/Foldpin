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

    init(file: NoteFile? = nil, localizationBundle: Bundle = .main) {
        self.localizationBundle = localizationBundle
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        self.file = file ?? NoteFile(url: base.appendingPathComponent("Foldpin", isDirectory: true).appendingPathComponent("note.json"))
        reload()
    }

    func reload() {
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

    func setPinned(_ value: Bool) {
        guard loadError == nil, document.isPinned != value else { return }
        document.isPinned = value
        scheduleSave()
    }

    func setShelved(_ value: Bool) {
        guard loadError == nil, document.isShelved != value else { return }
        document.isShelved = value
        scheduleSave()
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

    private func scheduleSave() {
        isDirty = true
        pendingSave?.cancel()
        pendingSave = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(450)) } catch { return }
            self?.flush()
        }
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
        return String(localized: "Could not register the shortcut (\(code)). Choose another in the menu bar.", bundle: localizationBundle)
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
