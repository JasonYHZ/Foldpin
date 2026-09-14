import AppKit
import UniformTypeIdentifiers

@MainActor final class NoteExportPresenter: NSObject {
    private let notes: [NoteExportSource]
    private let panel = NSSavePanel()
    private let formats = NSPopUpButton(frame: NSRect(x: 80, y: 0, width: 180, height: 28))
    private let bundle = LanguageSettings.shared.bundle
    private var format: NoteExportFormat { NoteExportFormat.allCases[max(0, formats.indexOfSelectedItem)] }
    private init(notes: [NoteExportSource]) { self.notes = notes; super.init() }

    static func present(_ notes: [NoteExportSource], in window: NSWindow) {
        guard !notes.isEmpty, window.attachedSheet == nil else { return }
        let presenter = NoteExportPresenter(notes: notes)
        presenter.show(in: window)
    }
    private func show(in window: NSWindow) {
        panel.title = String(localized: "Export Notes", bundle: bundle)
        panel.prompt = String(localized: "Export", bundle: bundle)
        panel.canCreateDirectories = true
        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 270, height: 32))
        let label = NSTextField(labelWithString: String(localized: "Format", bundle: bundle)); label.frame = NSRect(x: 0, y: 5, width: 76, height: 20)
        formats.addItems(withTitles: NoteExportFormat.allCases.map(\.title)); formats.target = self; formats.action = #selector(changeFormat)
        accessory.addSubview(label); accessory.addSubview(formats); panel.accessoryView = accessory
        panel.nameFieldStringValue = notes.count == 1 ? NoteExport.filename(notes[0].title) : "Foldpin"
        changeFormat()
        panel.beginSheetModal(for: window) { [self] response in
            guard response == .OK, let destination = panel.url else { return }
            let selectedFormat = format
            let progress = NSAlert()
            progress.messageText = String(localized: "Exporting notes…", bundle: bundle)
            progress.informativeText = String(localized: "Preparing documents and resources.", bundle: bundle)
            progress.addButton(withTitle: String(localized: "Cancel", bundle: bundle))
            let indicator = NSProgressIndicator(frame: NSRect(x: 0, y: 0, width: 260, height: 16))
            indicator.style = .bar; indicator.isIndeterminate = true; indicator.startAnimation(nil); progress.accessoryView = indicator
            let sources = notes
            let task = Task.detached(priority: .userInitiated) { try NoteExport.write(sources, format: selectedFormat, to: destination) }
            progress.beginSheetModal(for: window) { response in if response == .alertFirstButtonReturn { task.cancel() } }
            Task { @MainActor in
                do {
                    try await task.value
                    if window.attachedSheet === progress.window { window.endSheet(progress.window, returnCode: .OK) }
                } catch {
                    if window.attachedSheet === progress.window { window.endSheet(progress.window, returnCode: .OK) }
                    if !(error is CancellationError) { Self.showError(error, in: window) }
                }
            }
        }
    }
    @objc private func changeFormat() {
        let ext = NoteExport.isArchive(notes) ? "zip" : format.fileExtension
        panel.allowedContentTypes = [UTType(filenameExtension: ext) ?? .data]
        let name = panel.nameFieldStringValue
        let previous = (name as NSString).pathExtension.lowercased()
        panel.nameFieldStringValue = (["md", "html", "zip"].contains(previous) ? (name as NSString).deletingPathExtension : name) + "." + ext
    }
    static func showError(_ error: Error, in window: NSWindow) {
        let bundle = LanguageSettings.shared.bundle
        let alert = NSAlert(); alert.messageText = String(localized: "Could not export notes", bundle: bundle)
        alert.informativeText = String(localized: "Finish importing or recording and check that all resource files are available. Existing notes and exports are unchanged.", bundle: bundle) + "\n" + error.localizedDescription
        alert.beginSheetModal(for: window)
    }
}
