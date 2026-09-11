import Foundation
import Testing
@testable import FoldpinCore

@Test func blankNoteClosingRecognizesWhitespaceWithoutDiscardingContent() {
    #expect(NoteContent().isBlankForClosing)
    #expect(NoteContent(plainText: " \t\n\r\n\u{3000}").isBlankForClosing)
    for kind in NoteBlockKind.allCases where !kind.isAttachment {
        #expect(NoteContent(blocks: [NoteBlock(kind: kind, text: " \n")]).isBlankForClosing)
        #expect(!NoteContent(blocks: [NoteBlock(kind: kind, text: "内容")]).isBlankForClosing)
    }
    for kind in NoteBlockKind.allCases where kind.isAttachment {
        // Even incomplete/missing media must never be classified as disposable.
        #expect(!NoteContent(blocks: [NoteBlock(kind: kind)]).isBlankForClosing)
    }
    #expect(!NoteContent(blocks: [NoteBlock(kind: .task, isChecked: true)]).isBlankForClosing)
    #expect(!NoteContent(plainText: "\u{200B}").isBlankForClosing)
    #expect(!NoteContent(plainText: "\n\nhttps://example.com\n").isBlankForClosing)
}

@Test @MainActor func blankNoteDeletionStaysOffShelfAfterRestartAndCanBeRestored() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let library = NoteLibrary(directory: directory)
    let entry = try #require(library.entries.first)
    entry.store.edit(" \n\t")
    #expect(entry.store.document.content.isBlankForClosing)
    #expect(library.deleteNote(entry.id))
    #expect(library.entries.isEmpty)
    #expect(library.deletedEntries.first?.store === entry.store)
    let reopened = NoteLibrary(directory: directory)
    #expect(reopened.entries.isEmpty)
    #expect(reopened.deletedEntries.map(\.id) == [entry.id])
    let restored = try #require(reopened.restoreNote(entry.id))
    #expect(restored.store.document.text == " \n\t")
}
