import SwiftUI
import Combine

@MainActor
final class LibraryUsageModel: ObservableObject {
    @Published private(set) var report: LibraryUsage.Report?
    @Published private(set) var localDataBytes: Int64?
    @Published private(set) var busy = false
    @Published private(set) var error: String?
    private var task: Task<Void, Never>?
    func cancel() { task?.cancel() }
    func clear() { cancel(); report = nil; localDataBytes = nil; error = nil }
    func scan(storage: LibraryLocationController) {
        guard !busy, !storage.isBusy else { return }
        busy = true; error = nil; report = nil; localDataBytes = nil
        let library = storage.library, root = library.directory, serial = library.path.writeSerial
        let generation = storage.generation, snapshot = library.path.snapshot, privateDirectory = storage.privateDirectory
        task = Task {
            defer { busy = false; task = nil }
            do {
                let worker = Task.detached(priority: .utility) {
                    let result = try LibraryUsage.scan(root: root)
                    let local = try? LibraryUsage.scan(root: privateDirectory)
                    return (result, local?.incomplete == false ? local?.total : nil)
                }
                let result = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                try Task.checkCancellation()
                guard storage.library === library, library.directory == root, library.path.writeSerial == serial, storage.generation == generation,
                      library.path.snapshot.notes.mapValues(\.revision) == snapshot.notes.mapValues(\.revision),
                      library.path.snapshot.collections.mapValues(\.revision) == snapshot.collections.mapValues(\.revision), !storage.isBusy else { throw LibraryStorageError.changed }
                report = result.0; localDataBytes = result.1
            } catch is CancellationError { }
            catch { self.error = error.localizedDescription }
        }
    }
}

struct LibraryUsageView: View {
    @ObservedObject var storage: LibraryLocationController
    @StateObject private var model = LibraryUsageModel()
    @ObservedObject private var language = LanguageSettings.shared
    @State private var expanded = false
    let locate: (UUID) -> Void
    private func bytes(_ count: Int64) -> String { ByteCountFormatter.string(fromByteCount: count, countStyle: .file) }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(readinessText("Storage Usage"), systemImage: "chart.pie")
                Spacer()
                if model.busy {
                    ProgressView().controlSize(.small)
                    Button(readinessText("Cancel")) { model.cancel() }
                } else { Button(readinessText("Scan Storage")) { model.scan(storage: storage) }.disabled(storage.isBusy) }
            }
            if let error = model.error { Text(error).font(.callout).foregroundStyle(.red) }
            if let report = model.report {
                Text(bytes(report.total)).font(.title2.monospacedDigit())
                Text(report.date, style: .time).font(.caption).foregroundStyle(.secondary)
                if !report.incomplete, report.items.allSatisfy({ $0.allocatedBytes != nil }) {
                    HStack { Text(readinessText("On this Mac")); Spacer(); Text(bytes(report.items.reduce(0) { $0 + ($1.allocatedBytes ?? 0) })) }.font(.caption).foregroundStyle(.secondary)
                }
                if let local = model.localDataBytes {
                    HStack { Text(readinessText("Local App Data")); Spacer(); Text(bytes(local)) }.font(.caption)
                    Text(readinessText("Window positions, folder access and recovery records. These are required data, not disposable cache.")).font(.caption).foregroundStyle(.secondary)
                }
                if report.incomplete { Text(readinessText("Partial result. Some files are unavailable or could not be read; the total is a lower bound.")).font(.callout).foregroundStyle(.secondary) }
                ForEach(LibraryUsage.Category.allCases, id: \.self) { category in
                    if report.bytes(category) > 0 { HStack { Text(readinessText(category.rawValue)); Spacer(); Text(bytes(report.bytes(category))).monospacedDigit() }.font(.callout) }
                }
                DisclosureGroup(readinessText("Large Resources"), isExpanded: $expanded) {
                    ForEach(report.largestResources.prefix(20)) { item in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Text(item.relativePath.components(separatedBy: "/").last ?? "").lineLimit(1).truncationMode(.middle)
                                Spacer(); Text(bytes(item.bytes)).monospacedDigit()
                                Button(readinessText("Show in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([report.root.appendingPathComponent(item.relativePath)]) }
                            }
                            if item.references.isEmpty { Text(readinessText("No disk reference found. Undo history and clipboard may still use this resource.")).foregroundStyle(.secondary) }
                            ForEach(Array(item.references.enumerated()), id: \.offset) { _, reference in
                                HStack {
                                    Text(reference.title.isEmpty ? readinessText("Empty Note") : reference.title).lineLimit(1)
                                    if reference.historical { Text(readinessText("History")).foregroundStyle(.secondary) }
                                    if reference.deleted { Text(readinessText("Recently Deleted")).foregroundStyle(.secondary) }
                                    Spacer()
                                    if (storage.library.entries + storage.library.deletedEntries).contains(where: { $0.id == reference.noteID }) {
                                        Button(readinessText("Locate Note")) { locate(reference.noteID) }
                                    }
                                }
                            }
                        }.font(.caption).padding(.vertical, 5)
                        Divider()
                    }
                }
            }
            Text(readinessText("Historical revisions, recovery copies, undo and clipboard can still need attachments. Cleanup is unavailable until their references and sharing history can be verified.")).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .onChange(of: storage.library.directory) { _, _ in model.clear() }
        .onChange(of: storage.isBusy) { _, value in if value { model.clear() } }
        .onDisappear { model.cancel() }
    }
}
