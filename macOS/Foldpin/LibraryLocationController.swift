import AppKit
import SwiftUI
import Combine
import Darwin

@MainActor
final class LibraryFolderAccess {
    let url: URL
    private var scoped = false
    private var lockFD: Int32 = -1
    init(url: URL, lockDirectory: URL) throws {
        self.url = url
        scoped = url.startAccessingSecurityScopedResource()
        var acquired = false
        defer { if !acquired, scoped { url.stopAccessingSecurityScopedResource(); scoped = false } }
        try FileManager.default.createDirectory(at: lockDirectory, withIntermediateDirectories: true)
        var info = stat()
        guard stat(url.path, &info) == 0 else { throw LibraryStorageError.unavailable }
        let lockURL = lockDirectory.appendingPathComponent("\(info.st_dev)-\(info.st_ino).lock")
        lockFD = Darwin.open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard lockFD >= 0, flock(lockFD, LOCK_EX | LOCK_NB) == 0 else {
            if lockFD >= 0 { Darwin.close(lockFD); lockFD = -1 }
            throw LibraryStorageError.locked
        }
        acquired = true
    }
    isolated deinit {
        if lockFD >= 0 { flock(lockFD, LOCK_UN); Darwin.close(lockFD) }
        if scoped { url.stopAccessingSecurityScopedResource() }
    }
}

@MainActor
final class LibraryLocationController: ObservableObject {
    private struct Selection: Codable { let bookmark: Data; let libraryID: UUID; var lastKnownURL: URL? }
    @Published private(set) var library: NoteLibrary
    @Published private(set) var isBusy = false
    @Published private(set) var progress: Double = 0
    @Published private(set) var status = ""
    @Published private var lastError: Error?
    var failure: String? {
        guard let lastError else { return nil }
        return (lastError as? LibraryStorageError)?.description(bundle: LanguageSettings.shared.bundle) ?? lastError.localizedDescription
    }
    var prepare: (() throws -> Void)?
    var didSwitch: ((NoteLibrary, Bool) -> Void)?
    var willRefresh: (() -> Bool)?
    var didRefresh: (() -> Void)?
    var resourcesArrived: ((Set<UUID>) -> Void)?
    private var pendingResources = Set<UUID>()
    let privateDirectory: URL
    private let defaultDirectory: URL
    private var access: LibraryFolderAccess?
    private var cache: [URL: (NoteLibrary, LibraryFolderAccess?)] = [:]
    private var task: Task<Void, Never>?
    private var poll: Task<Void, Never>?
    private var refreshing = false
    private var epoch = 0
    private var retryOperation: (() -> Void)?
    private var startupURL: URL?
    private var startupID: UUID?
    let firstRunCandidate: Bool
    var isGettingStartedLibrary: Bool {
        firstRunCandidate && library.directory == defaultDirectory && library.path.manifest == nil
    }
    var generation: Int { epoch }
    var isRefreshing: Bool { refreshing }
    private var selectionURL: URL { privateDirectory.appendingPathComponent("location.json") }
    private var journalURL: URL { privateDirectory.appendingPathComponent("relocation.json") }
    init(privateDirectory: URL? = nil, defaultDirectory: URL? = nil) {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        self.privateDirectory = privateDirectory ?? support.appendingPathComponent("FoldpinLocalState")
        self.defaultDirectory = defaultDirectory ?? support.appendingPathComponent("Foldpin")
        let preference = self.privateDirectory.appendingPathComponent("location.json")
        firstRunCandidate = !UserDefaults.standard.bool(forKey: "gettingStarted.completed") &&
            (UserDefaults.standard.bool(forKey: "gettingStarted.eligible") ||
             (!FileManager.default.fileExists(atPath: preference.path) && !FileManager.default.fileExists(atPath: self.defaultDirectory.path)))
        var lastKnownURL = self.defaultDirectory
        if FileManager.default.fileExists(atPath: preference.path) {
            do {
                let selection = try JSONDecoder().decode(Selection.self, from: Data(contentsOf: preference))
                lastKnownURL = selection.lastKnownURL ?? lastKnownURL
                var stale = false
                let url = try URL(resolvingBookmarkData: selection.bookmark, options: [.withSecurityScope, .withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale)
                startupURL = url; startupID = selection.libraryID
                library = NoteLibrary(directory: url, localDirectory: self.privateDirectory, initialError: LibraryStorageError.downloading)
            } catch {
                library = NoteLibrary(directory: lastKnownURL, localDirectory: self.privateDirectory, initialError: error)
                lastError = error
            }
        } else {
            do {
                try FileManager.default.createDirectory(at: self.defaultDirectory, withIntermediateDirectories: true)
                access = try LibraryFolderAccess(url: self.defaultDirectory, lockDirectory: self.privateDirectory.appendingPathComponent("locks"))
                library = NoteLibrary(directory: self.defaultDirectory, localDirectory: self.privateDirectory, createsInitialNote: !firstRunCandidate)
            } catch {
                library = NoteLibrary(directory: self.defaultDirectory, localDirectory: self.privateDirectory, initialError: error)
                lastError = error
            }
        }
    }
    func start() {
        if let startupURL { open(startupURL, expectedID: startupID, restoring: true) }
        if FileManager.default.fileExists(atPath: journalURL.path) {
            status = "A previous storage change was interrupted. Your original library is kept. Retry the move, or open the completed destination."
        }
        poll = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
                guard let self else { return }
                if !isBusy, let startupURL, case LibraryStorageError.downloading? = lastError {
                    open(startupURL, expectedID: startupID, restoring: true)
                } else { await refresh() }
            }
        }
    }
    func reveal() { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: library.directory.path) }
    func retry() {
        if let retryOperation { retryOperation(); return }
        if let startupURL { open(startupURL, expectedID: startupID, restoring: true) }
        else if library.path.manifest == nil, library.failure != nil {
            if FileManager.default.fileExists(atPath: selectionURL.path) { chooseExisting(); return }
            do {
                if access == nil { access = try LibraryFolderAccess(url: library.directory, lockDirectory: privateDirectory.appendingPathComponent("locks")) }
                library.reload(); lastError = library.failure
                if library.failure == nil { didSwitch?(library, true) }
            } catch { lastError = error }
        } else { Task { await refresh() } }
    }
    func commandChangeLocation(_ action: String, validate: () throws -> Void) async throws {
        guard !isBusy else { throw MCPFailure("busy_editing") }
        if action == "default" { try validate(); useDefault(); return }
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false; panel.canCreateDirectories = action == "move"
        guard await panel.begin() == .OK, let selected = panel.url else { throw MCPFailure("cancelled") }
        try validate()
        if action == "move" { move(to: selected.appendingPathComponent("Foldpin Library"), granting: selected) }
        else { open(selected) }
    }

    func chooseExisting() {
        guard !isBusy else { return }
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = false
        panel.message = text("Choose an existing Foldpin library, including a folder in iCloud Drive.")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        open(url)
    }
    func chooseDestination() {
        guard !isBusy else { return }
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = text("Choose a parent folder. Foldpin Library will be created inside it. You can choose iCloud Drive.")
        guard panel.runModal() == .OK, let parent = panel.url else { return }
        move(to: parent.appendingPathComponent("Foldpin Library"), granting: parent)
    }
    // The original default folder remains a recovery copy after upgrading.
    // Its managed successor is also app-owned, so neither requires a picker.
    private var upgradedDefaultDirectory: URL { defaultDirectory.appendingPathExtension("library") }
    private func sameLocation(_ a: URL, _ b: URL) -> Bool {
        a.resolvingSymlinksInPath().path == b.resolvingSymlinksInPath().path
    }
    private var isUsingDefault: Bool {
        sameLocation(library.directory, defaultDirectory) || sameLocation(library.directory, upgradedDefaultDirectory)
    }
    func useDefault() {
        guard !isBusy else { return }
        if isUsingDefault, library.failure == nil { status = "You are already using the default library."; return }
        if FileManager.default.fileExists(atPath: defaultDirectory.path) || FileManager.default.fileExists(atPath: upgradedDefaultDirectory.path) {
            let alert = NSAlert(); alert.messageText = text("Open the default library?")
            alert.informativeText = text("Foldpin will open the library saved in its default location and upgrade it automatically if needed. The original files are kept. Your current library will not be moved or merged.")
            alert.addButton(withTitle: text("Cancel")); alert.addButton(withTitle: text("Open This Library"))
            if alert.runModal() == .alertSecondButtonReturn { openDefaultLibrary() }
        } else { openDefaultLibrary() }
    }
    func openDefaultLibrary() {
        guard !isBusy else { return }
        if isUsingDefault, library.failure == nil { status = "You are already using the default library."; return }
        // A promoted copy from an interrupted upgrade is reused only after
        // the migration's existing source/target checksum checks pass.
        let unfinished = (try? Data(contentsOf: journalURL)).flatMap { try? JSONDecoder().decode(LibraryMoveJournal.self, from: $0) }
        let shouldResume = unfinished.map { sameLocation($0.source, defaultDirectory) && sameLocation($0.destination, upgradedDefaultDirectory) } == true
        if FileManager.default.fileExists(atPath: upgradedDefaultDirectory.path), !shouldResume {
            open(upgradedDefaultDirectory)
        } else if FileManager.default.fileExists(atPath: defaultDirectory.path) {
            open(defaultDirectory, automaticUpgradeDestination: upgradedDefaultDirectory)
        } else { move(to: defaultDirectory, granting: defaultDirectory.deletingLastPathComponent()) }
    }
    func cancel() { task?.cancel() }
    private func text(_ value: String) -> String { LanguageSettings.shared.bundle.localizedString(forKey: value, value: value, table: nil) }
    private func begin(restoring: Bool = false) throws {
        guard !isBusy, !refreshing, LibraryFileActivity.imports == 0 else { throw LibraryStorageError.busy }
        if !restoring { try prepare?() }
        isBusy = true; lastError = nil; progress = 0; epoch += 1
        library.setSuspended(true)
    }
    private func finish(_ error: Error? = nil) {
        library.setSuspended(false)
        isBusy = false; task = nil
        if error == nil { retryOperation = nil }
        if let error, !(error is CancellationError) { lastError = error }
        else if error is CancellationError { status = "Storage change cancelled. The original library is unchanged." }
    }
    private func persist(_ prepared: LibraryPreparedLocation, access: LibraryFolderAccess) throws {
        // location.json is the sole commit point. Before this atomic replacement,
        // restart uses the previous location; afterwards it validates this target.
        let bookmark = try access.url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        var stale = false
        let resolved = try URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale)
        guard resolved.resolvingSymlinksInPath().path == prepared.root.resolvingSymlinksInPath().path else { throw LibraryStorageError.changed }
        let path = LibraryPath(prepared.root, manifest: prepared.manifest, localDirectory: privateDirectory)
        for note in prepared.desktops { try LibraryDisk.desktop(note, at: path) }
        try FileManager.default.createDirectory(at: privateDirectory, withIntermediateDirectories: true)
        try LibraryDisk.encode(Selection(bookmark: bookmark, libraryID: prepared.manifest.id, lastKnownURL: prepared.root)).write(to: selectionURL, options: .atomic)
    }
    func open(_ url: URL, expectedID: UUID? = nil, restoring: Bool = false, automaticUpgradeDestination: URL? = nil) {
        retryOperation = { [weak self] in self?.open(url, expectedID: expectedID, restoring: restoring, automaticUpgradeDestination: automaticUpgradeDestination) }
        do { try begin(restoring: restoring) } catch { lastError = error; return }
        task = Task { [weak self] in
            guard let self else { return }
            var upgradeScope: URL?
            defer { upgradeScope?.stopAccessingSecurityScopedResource() }
            do {
                let key = url.resolvingSymlinksInPath().standardizedFileURL
                let currentAccess = key == library.directory.resolvingSymlinksInPath().standardizedFileURL ? access : nil
                let newAccess = try currentAccess ?? cache[key]?.1 ?? LibraryFolderAccess(url: url, lockDirectory: privateDirectory.appendingPathComponent("locks"))
                let probe = try await Task.detached(priority: .userInitiated) { try LibraryRelocation.probe(url) }.value
                let prepared: LibraryPreparedLocation
                let selectedAccess: LibraryFolderAccess
                if let manifest = probe.0 {
                    if let expectedID, manifest.id != expectedID { throw LibraryStorageError.changed }
                    prepared = try await Task.detached(priority: .userInitiated) {
                        let snapshot = try LibraryDisk.snapshot(url, reconcile: false)
                        _ = try LibraryDisk.pendingResources(snapshot, root: url)
                        return LibraryPreparedLocation(root: url, manifest: manifest, snapshot: snapshot, desktops: [])
                    }.value
                    selectedAccess = newAccess
                } else {
                    guard !restoring else { throw LibraryStorageError.unrecognized }
                    let destination: URL
                    if let automaticUpgradeDestination {
                        destination = automaticUpgradeDestination
                    } else {
                        let alert = NSAlert(); alert.messageText = text("Upgrade this older library?")
                        alert.informativeText = text("A checked copy will be created in the location you choose next. The original library and its files will be kept.")
                        alert.addButton(withTitle: text("Cancel")); alert.addButton(withTitle: text("Upgrade and Open"))
                        guard alert.runModal() == .alertSecondButtonReturn else { throw CancellationError() }
                        let panel = NSOpenPanel()
                        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true
                        panel.allowsMultipleSelection = false; panel.directoryURL = url.deletingLastPathComponent()
                        panel.message = text("Choose a parent folder. Foldpin Library will be created inside it. You can choose iCloud Drive.")
                        guard panel.runModal() == .OK, let parent = panel.url else { throw CancellationError() }
                        if parent.startAccessingSecurityScopedResource() { upgradeScope = parent }
                        destination = parent.appendingPathComponent("Foldpin Library")
                    }
                    let journal = journalURL
                    let worker = Task.detached(priority: .userInitiated) { try LibraryRelocation.copy(source: url, destination: destination, journalURL: journal) }
                    prepared = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                    selectedAccess = try LibraryFolderAccess(url: destination, lockDirectory: privateDirectory.appendingPathComponent("locks"))
                }
                try Task.checkCancellation()
                try persist(prepared, access: selectedAccess)
                let previous = library
                cache[previous.directory.resolvingSymlinksInPath().standardizedFileURL] = (previous, access)
                let selectedKey = prepared.root.resolvingSymlinksInPath().standardizedFileURL
                let next = cache[selectedKey]?.0 ?? NoteLibrary(directory: prepared.root, manifest: prepared.manifest, snapshot: prepared.snapshot, localDirectory: privateDirectory)
                next.apply(prepared.snapshot)
                access = selectedAccess; library = next; startupURL = nil; startupID = nil
                if let data = try? Data(contentsOf: journalURL),
                   let journal = try? JSONDecoder().decode(LibraryMoveJournal.self, from: data),
                   journal.destination.resolvingSymlinksInPath().path == prepared.root.resolvingSymlinksInPath().path {
                    try? FileManager.default.removeItem(at: journalURL)
                }
                status = "Library opened. iCloud Drive transfers files in the background."
                pendingResources = Set(prepared.snapshot.notes.keys)
                finish()
                didSwitch?(previous, false)
            } catch { finish(error) }
        }
    }
    private func move(to destination: URL, granting parent: URL) {
        retryOperation = { [weak self] in self?.move(to: destination, granting: parent) }
        let source = library.directory
        let alert = NSAlert(); alert.messageText = text("Move this library?")
        alert.informativeText = source.path + "\n→\n" + destination.path + "\n\n" + text("All notes and attachments will be copied and checked. The original folder will be kept.") + "\n\n" + text("On other Macs, open the new location after this move. The original folder will not receive new changes.")
        alert.addButton(withTitle: text("Cancel")); alert.addButton(withTitle: text("Move Library"))
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        do { try begin() } catch { lastError = error; return }
        let journal = journalURL
        task = Task { [weak self] in
            guard let self else { return }
            let scope = parent.startAccessingSecurityScopedResource()
            defer { if scope { parent.stopAccessingSecurityScopedResource() } }
            do {
                let worker = Task.detached(priority: .userInitiated) {
                    try LibraryRelocation.copy(source: source, destination: destination, journalURL: journal) { value in
                        Task { @MainActor [weak self] in self?.progress = value }
                    }
                }
                let prepared = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                try Task.checkCancellation()
                let newAccess = try LibraryFolderAccess(url: destination, lockDirectory: privateDirectory.appendingPathComponent("locks"))
                try persist(prepared, access: newAccess)
                library.relocate(to: destination, manifest: prepared.manifest, snapshot: prepared.snapshot)
                access = newAccess
                try? FileManager.default.removeItem(at: journal)
                status = "Library moved. The original folder has been kept."
                pendingResources = Set(prepared.snapshot.notes.keys)
                finish()
                didSwitch?(library, true)
            } catch { finish(error) }
        }
    }
    private func refresh() async {
        guard !isBusy, !refreshing, library.path.manifest != nil else { return }
        guard willRefresh?() != false else { return }
        refreshing = true
        defer { refreshing = false }
        let generation = epoch, current = library, root = library.directory, serial = library.path.writeSerial
        do {
            let expectedID = current.path.manifest?.id
            let snapshot = try await Task.detached(priority: .utility) {
                guard try LibraryDisk.manifest(at: root).id == expectedID else { throw LibraryStorageError.changed }
                let snapshot = try LibraryDisk.snapshot(root)
                return try (snapshot, LibraryDisk.pendingResources(snapshot, root: root))
            }.value
            guard epoch == generation, library === current, willRefresh?() != false, current.path.writeSerial == serial else { return }
            guard Set(current.path.snapshot.notes.keys).isSubset(of: Set(snapshot.0.notes.keys)),
                  Set(current.path.snapshot.collections.keys).isSubset(of: Set(snapshot.0.collections.keys)) else { throw LibraryStorageError.downloading }
            let previous = current.path.snapshot
            if previous.notes.mapValues(\.revision) != snapshot.0.notes.mapValues(\.revision)
                || previous.collections.mapValues(\.revision) != snapshot.0.collections.mapValues(\.revision) {
                current.apply(snapshot.0); didRefresh?()
            }
            let arrived = pendingResources.subtracting(snapshot.1)
            let previouslyPending = !pendingResources.isEmpty
            pendingResources = snapshot.1
            if !arrived.isEmpty { resourcesArrived?(arrived) }
            if !pendingResources.isEmpty { status = "Some attachments are not available locally yet. Foldpin has requested their iCloud download." }
            else if previouslyPending { status = "Attachments are available locally." }
            if failure != nil { lastError = nil }
        } catch { lastError = error }
    }
}
