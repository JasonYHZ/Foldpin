import Foundation
import Testing
@testable import FoldpinCore

@Suite @MainActor struct GettingStartedNoteTests {
    private func fixture() throws -> (URL, UserDefaults, String) {
        let name = "Foldpin.FirstNote.Tests." + UUID().uuidString
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        return (root, try #require(UserDefaults(suiteName: name)), name)
    }
    @Test func firstLaunchCreatesOneEditableNoteAndKeepsEdits() throws {
        let (root, defaults, name) = try fixture()
        defer { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: name) }
        let library = NoteLibrary(directory: root, localDirectory: root.appendingPathComponent("local"), createsInitialNote: false)
        let shortcuts = ShortcutSettings(defaults: defaults)
        let guide = GettingStartedNote(defaults: defaults)
        let entry = try #require(try guide.createOnFirstLaunch(in: library, eligible: true, bundle: .main, shortcuts: shortcuts))
        #expect(library.entries.count == 1)
        #expect(!entry.store.document.isShelved && !entry.store.document.isCollapsed)
        #expect(entry.store.document.text.contains("⌘N"))
        #expect(guide.completed)
        entry.store.edit("My own notes now"); #expect(entry.store.flush())
        let before = try Data(contentsOf: entry.store.file.url)
        let restarted = GettingStartedNote(defaults: defaults)
        #expect(try restarted.createOnFirstLaunch(in: library, eligible: true, bundle: .main, shortcuts: shortcuts) == nil)
        let manual = try restarted.open(in: library, bundle: .main, shortcuts: shortcuts)
        #expect(manual.store === entry.store)
        #expect(try Data(contentsOf: entry.store.file.url) == before)
        #expect(library.entries.count == 1)
    }
    @Test func deletedGuideIsNotAutomaticallyRecreated() throws {
        let (root, defaults, name) = try fixture()
        defer { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: name) }
        let library = NoteLibrary(directory: root, localDirectory: root.appendingPathComponent("local"), createsInitialNote: false)
        let shortcuts = ShortcutSettings(defaults: defaults), guide = GettingStartedNote(defaults: defaults)
        let entry = try #require(try guide.createOnFirstLaunch(in: library, eligible: true, bundle: .main, shortcuts: shortcuts))
        #expect(library.deleteNote(entry.id))
        #expect(try guide.createOnFirstLaunch(in: library, eligible: true, bundle: .main, shortcuts: shortcuts) == nil)
        #expect(try guide.open(in: library, bundle: .main, shortcuts: shortcuts).store.document.deletedAt != nil)
        try library.permanentlyDeleteNote(entry.id)
        #expect(try guide.createOnFirstLaunch(in: library, eligible: true, bundle: .main, shortcuts: shortcuts) == nil)
        let explicit = try guide.open(in: library, bundle: .main, shortcuts: shortcuts)
        #expect(explicit.id != entry.id)
        #expect(library.entries.count == 1)
    }
    @Test func existingOrUnavailableLibrariesDoNotReceiveAutomaticGuide() throws {
        let (root, defaults, name) = try fixture()
        defer { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: name) }
        let library = NoteLibrary(directory: root, localDirectory: root.appendingPathComponent("local"), createsInitialNote: false)
        let shortcuts = ShortcutSettings(defaults: defaults), guide = GettingStartedNote(defaults: defaults)
        #expect(try guide.createOnFirstLaunch(in: library, eligible: false, bundle: .main, shortcuts: shortcuts) == nil)
        library.setSuspended(true)
        #expect(try guide.createOnFirstLaunch(in: library, eligible: true, bundle: .main, shortcuts: shortcuts) == nil)
        #expect(!guide.completed)
        #expect(throws: (any Error).self) { try guide.open(in: library, bundle: .main, shortcuts: shortcuts) }
        #expect(!guide.completed)
        library.setSuspended(false)
        let existing = try #require(library.createNote())
        existing.store.edit("Already in the library"); #expect(existing.store.flush())
        #expect(try guide.createOnFirstLaunch(in: library, eligible: true, bundle: .main, shortcuts: shortcuts) == nil)
        #expect(library.entries.count == 1 && existing.store.document.text == "Already in the library")
    }
}
