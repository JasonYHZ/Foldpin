import SwiftUI
import Combine
import UniformTypeIdentifiers

@MainActor
final class MarkdownFileImportController: ObservableObject {
    struct Row: Identifiable {
        let id = UUID()
        let source: URL
        var noteID = UUID()
        var state = "Waiting"
        var detail = ""
        var warnings: [String] = []
        var succeeded = false
        var sourceBytes = 0
        var resourceBytes = 0
    }
    @Published private(set) var rows: [Row] = []
    @Published private(set) var busy = false
    @Published private(set) var progress: Double = 0
    @Published var skipUnresolved = false
    private var resourceRoot: URL?
    private var library: NoteLibrary?
    private var root: URL?
    private var task: Task<Void, Never>?
    private var window: NSWindow?
    private var storage: LibraryLocationController?
    var onOpen: ((UUID) -> Void)?
    func choose(storage: LibraryLocationController) {
        if busy { show(); return }
        guard !storage.isBusy, storage.library.canCreate else { return }
        let panel = NSOpenPanel(); panel.allowsMultipleSelection = true; panel.canChooseDirectories = false
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText, UTType(filenameExtension: "markdown") ?? .plainText]
        panel.message = readinessText("Import up to 50 Markdown files. Each file becomes a collected note.")
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        guard panel.urls.count <= 50 else { showError(CocoaError(.fileReadTooLarge)); return }
        let alert = NSAlert()
        alert.messageText = readinessText("Include local resources?")
        alert.informativeText = readinessText("Choose a resource folder to copy standalone Markdown images and file links. Other formatting and unresolved links are kept as source text. Remote resources are never downloaded.")
        alert.addButton(withTitle: readinessText("Choose Resource Folder…"))
        alert.addButton(withTitle: readinessText("Keep Links"))
        alert.addButton(withTitle: readinessText("Cancel"))
        let result = alert.runModal()
        guard result != .alertThirdButtonReturn else { return }
        resourceRoot = nil
        if result == .alertFirstButtonReturn {
            let folder = NSOpenPanel(); folder.canChooseFiles = false; folder.canChooseDirectories = true; folder.allowsMultipleSelection = false
            folder.directoryURL = panel.urls.first?.deletingLastPathComponent()
            guard folder.runModal() == .OK, let selected = folder.url else { return }
            resourceRoot = selected
        }
        configure(sources: panel.urls, storage: storage, resourceRoot: resourceRoot)
        show()
    }
    func configure(sources: [URL], storage: LibraryLocationController, resourceRoot: URL?) {
        guard !busy else { return }
        self.storage = storage; library = storage.library; root = storage.library.directory; self.resourceRoot = resourceRoot
        rows = sources.map { Row(source: $0) }; progress = 0
    }
    func cancel() { task?.cancel() }
    func show() {
        if window == nil {
            let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 610, height: 460), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            panel.title = "Foldpin"; panel.isReleasedWhenClosed = false; panel.minSize = NSSize(width: 480, height: 350)
            panel.contentView = NSHostingView(rootView: MarkdownImportView(model: self)); panel.center(); window = panel
        }
        NSApp.activate(); window?.makeKeyAndOrderFront(nil)
    }
    func open(_ id: UUID) { guard storage?.library === library else { return }; onOpen?(id) }
    func run() {
        guard !busy, !rows.isEmpty, rows.count <= 50, let storage, let library, let root, storage.library === library,
              !storage.isBusy, !storage.isRefreshing, library.canCreate, library.directory == root else { showError(LibraryStorageError.changed); return }
        busy = true; LibraryFileActivity.imports += 1
        let resourceRoot = resourceRoot, skip = skipUnresolved
        let generation = storage.generation
        task = Task {
            defer { busy = false; task = nil; LibraryFileActivity.imports -= 1 }
            let pending = rows.indices.filter { !rows[$0].succeeded && rows[$0].state != "Skipped" }
            var sourceBytes = rows.filter(\.succeeded).reduce(0) { $0 + $1.sourceBytes }
            var resourceBytes = rows.filter(\.succeeded).reduce(0) { $0 + $1.resourceBytes }
            for (position, index) in pending.enumerated() {
                if Task.isCancelled { break }
                rows[index].state = "Importing…"; rows[index].detail = ""; rows[index].warnings = []
                let url = rows[index].source
                let remaining = MarkdownFileImport.resourceLimit - resourceBytes
                let staging = FileManager.default.temporaryDirectory.appendingPathComponent("Foldpin-import-" + UUID().uuidString)
                var published: [URL] = []
                var commitAttempted = false
                defer {
                    try? FileManager.default.removeItem(at: staging)
                    if !commitAttempted { for url in published { try? FileManager.default.removeItem(at: url) } }
                }
                do {
                    guard storage.library === library, storage.generation == generation, library.directory == root, library.canCreate else { throw LibraryStorageError.changed }
                    let worker = Task.detached(priority: .userInitiated) {
                        let access = url.startAccessingSecurityScopedResource(), resourceAccess = resourceRoot?.startAccessingSecurityScopedResource() == true
                        defer { if access { url.stopAccessingSecurityScopedResource() }; if resourceAccess { resourceRoot?.stopAccessingSecurityScopedResource() } }
                        let info = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
                        guard ["md", "markdown"].contains(url.pathExtension.lowercased()), info.isRegularFile == true, info.isSymbolicLink != true, let count = info.fileSize,
                              count <= MarkdownFileImport.fileLimit else { throw CocoaError(.fileReadTooLarge) }
                        let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
                        let data = try file.read(upToCount: MarkdownFileImport.fileLimit + 1) ?? Data()
                        let source = try MarkdownFileImport.decode(data)
                        return (try MarkdownFileImport.prepare(source: source, sourceURL: url, authorizedRoot: resourceRoot, staging: staging, remainingBytes: remaining), data.count)
                    }
                    let (prepared, count) = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                    try Task.checkCancellation()
                    sourceBytes += count
                    guard sourceBytes <= MarkdownFileImport.batchLimit else { throw CocoaError(.fileReadTooLarge) }
                    rows[index].warnings = prepared.warnings
                    if skip && !prepared.warnings.isEmpty { rows[index].state = "Skipped"; continue }
                    var document = NoteDocument(); document.id = rows[index].noteID; document.content = prepared.content; document.isShelved = true
                    let files = LibraryUsage.assetPaths(document), assets = root.appendingPathComponent("assets")
                    // UUID resources are promoted before the atomic note write. If
                    // that write is ambiguous, keep them rather than break a saved note.
                    let publisher = Task.detached(priority: .userInitiated) {
                        var created: [URL] = [], complete = false
                        defer { if !complete { for url in created { try? FileManager.default.removeItem(at: url) } } }
                        for relative in files {
                            try Task.checkCancellation()
                            let suffix = String(relative.dropFirst("assets/".count))
                            let source = staging.appendingPathComponent(suffix), target = assets.appendingPathComponent(suffix)
                            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                            try FileManager.default.moveItem(at: source, to: target)
                            created.append(target)
                        }
                        complete = true
                        return created
                    }
                    published = try await withTaskCancellationHandler { try await publisher.value } onCancel: { publisher.cancel() }
                    try Task.checkCancellation()
                    guard storage.library === library, storage.generation == generation, library.directory == root, library.canCreate else { throw LibraryStorageError.changed }
                    commitAttempted = true
                    let entry = try library.importDocument(document)
                    rows[index].noteID = entry.id; rows[index].succeeded = true; rows[index].state = "Imported"
                    rows[index].sourceBytes = count; rows[index].resourceBytes = prepared.resourceBytes
                    resourceBytes += prepared.resourceBytes
                } catch is CancellationError { rows[index].state = "Cancelled"; break }
                catch { rows[index].state = "Failed"; rows[index].detail = error.localizedDescription }
                progress = Double(position + 1) / Double(max(1, pending.count))
            }
            for index in rows.indices where rows[index].state == "Waiting" || rows[index].state == "Importing…" { rows[index].state = "Cancelled" }
            if rows.count == 1, let row = rows.first, row.succeeded { onOpen?(row.noteID) }
        }
    }
    private func showError(_ error: Error) {
        let alert = NSAlert(); alert.messageText = readinessText("Could not import Markdown"); alert.informativeText = error.localizedDescription; alert.runModal()
    }
}

private struct MarkdownImportView: View {
    @ObservedObject var model: MarkdownFileImportController
    @ObservedObject private var language = LanguageSettings.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(readinessText("Import Markdown Title")).font(.title2.bold())
            Text(readinessText("Standalone local images become image blocks. Standalone file links, including audio and video, become file attachments. Inline resources and unsupported syntax stay as source text.")).font(.callout).foregroundStyle(.secondary)
            Toggle(readinessText("Skip files with unresolved resources or formatting"), isOn: $model.skipUnresolved).disabled(model.busy)
            List(model.rows) { row in
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text(row.source.lastPathComponent).lineLimit(1)
                        Spacer(); Text(readinessText(row.state)).foregroundStyle(.secondary)
                        if row.succeeded { Button(readinessText("Locate Note")) { model.open(row.noteID) } }
                    }
                    if !row.detail.isEmpty { Text(row.detail).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
                    ForEach(row.warnings, id: \.self) { Text(readinessText($0)).font(.caption).foregroundStyle(.secondary) }
                }.padding(.vertical, 4)
            }
            if model.busy { ProgressView(value: model.progress) }
            HStack {
                Text("\(model.rows.filter(\.succeeded).count) / \(model.rows.count)").monospacedDigit().foregroundStyle(.secondary)
                Spacer()
                if model.busy { Button(readinessText("Cancel")) { model.cancel() } }
                else { Button(readinessText("Import Remaining Files")) { model.run() }.disabled(model.rows.allSatisfy { $0.succeeded || $0.state == "Skipped" }) }
            }
        }.padding(20).environment(\.locale, language.locale)
    }
}
