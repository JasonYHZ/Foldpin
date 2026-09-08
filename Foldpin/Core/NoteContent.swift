import Foundation

enum NoteBlockKind: String, Codable, CaseIterable, Sendable {
    case paragraph, heading, subheading, bullet, task, quote, code, image
}

enum CodeLanguage: String, Codable, CaseIterable, Sendable {
    case plain, swift, javascript, typescript, python, json, sql, shell
}

struct NoteTextMark: Codable, Equatable, Sendable {
    var location: Int
    var length: Int
    var bold = false
    var italic = false
}

struct NoteImage: Codable, Equatable, Sendable {
    var id: UUID
    var name: String
    var pixelWidth: Int
    var pixelHeight: Int
}

struct NoteBlock: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var kind: NoteBlockKind = .paragraph
    var text = ""
    var marks: [NoteTextMark] = []
    var isChecked = false
    var language: CodeLanguage = .plain
    var image: NoteImage?

    var plainText: String { image.map { "[\($0.name)]" } ?? text }
}

struct NoteContent: Codable, Equatable, Sendable {
    var schemaVersion = 1
    var blocks: [NoteBlock] = [NoteBlock()]

    init() {}
    init(blocks: [NoteBlock]) { self.blocks = blocks.isEmpty ? [NoteBlock()] : blocks }
    init(plainText: String) {
        // Preserve literal Markdown, CRLF, indentation, trailing lines and Unicode.
        blocks = plainText.components(separatedBy: "\n").map { NoteBlock(text: $0) }
    }

    var plainText: String { blocks.map(\.plainText).joined(separator: "\n") }
    var isEmpty: Bool { blocks.allSatisfy { $0.text.isEmpty && $0.image == nil } }

    func validate() throws {
        guard schemaVersion == 1 else { throw NoteFileError.unsupportedVersion }
        guard !blocks.isEmpty, Set(blocks.map(\.id)).count == blocks.count else {
            throw NoteFileError.invalidContent
        }
        for block in blocks {
            let length = (block.text as NSString).length
            guard block.marks.allSatisfy({
                $0.location >= 0 && $0.length > 0 && $0.location <= length && $0.length <= length - $0.location
            }) else { throw NoteFileError.invalidContent }
            if block.kind == .image {
                guard let image = block.image, image.pixelWidth > 0, image.pixelHeight > 0,
                      block.text.isEmpty, block.marks.isEmpty else { throw NoteFileError.invalidContent }
            } else if block.image != nil {
                throw NoteFileError.invalidContent
            }
        }
    }
}
