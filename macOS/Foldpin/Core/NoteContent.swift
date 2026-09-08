import Foundation

enum NoteBlockKind: String, Codable, CaseIterable, Sendable {
    // Keep the existing H1 / H2 raw values compatible with saved notes.
    case paragraph, heading, subheading, heading3, heading4, bullet, orderedList, task, quote, divider, table, code, image

    var isAttachment: Bool { [.image, .divider, .table].contains(self) }

    var headingLevel: Int? {
        switch self {
        case .heading: 1
        case .subheading: 2
        case .heading3: 3
        case .heading4: 4
        default: nil
        }
    }
}

nonisolated enum CodeLanguage: String, Codable, CaseIterable, Sendable {
    case automatic = "auto"
    case plain, html, swift, java, javascript, typescript, python, json, sql, shell
    case css, c, cpp, csharp, go, rust, kotlin, ruby, php, yaml, markdown, diff, ini
    case objectivec, lua, dart, r, makefile, dockerfile, graphql

    func title(bundle: Bundle) -> String {
        switch self {
        case .automatic: String(localized: "Auto-detect", bundle: bundle)
        case .plain: String(localized: "Plain Text", bundle: bundle)
        case .html: "HTML"
        case .swift: "Swift"
        case .java: "Java"
        case .javascript: "JavaScript"
        case .typescript: "TypeScript"
        case .python: "Python"
        case .json: "JSON"
        case .sql: "SQL"
        case .shell: "Shell"
        case .css: "CSS"
        case .c: "C"
        case .cpp: "C++"
        case .csharp: "C#"
        case .go: "Go"
        case .rust: "Rust"
        case .kotlin: "Kotlin"
        case .ruby: "Ruby"
        case .php: "PHP"
        case .yaml: "YAML"
        case .markdown: "Markdown"
        case .diff: "Diff"
        case .ini: "INI / TOML"
        case .objectivec: "Objective-C"
        case .lua: "Lua"
        case .dart: "Dart"
        case .r: "R"
        case .makefile: "Makefile"
        case .dockerfile: "Dockerfile"
        case .graphql: "GraphQL"
        }
    }

    var grammarName: String {
        switch self {
        case .html: "xml"
        case .shell: "bash"
        default: rawValue
        }
    }

    init?(grammarName: String) {
        switch grammarName {
        case "xml": self = .html
        case "bash": self = .shell
        default:
            guard let value = Self(rawValue: grammarName) else { return nil }
            self = value
        }
    }

    // Prose-like grammars require clear structural hints; keep them out of the
    // statistical pool so punctuation alone doesn't classify ordinary text.
    static let detectionCandidates = allCases.filter {
        ![.automatic, .plain, .markdown, .diff, .ini, .makefile, .r].contains($0)
    }

    func resolved(for text: String) -> CodeLanguage {
        self == .automatic ? CodeLanguageDetector.detect(text) : self
    }

    func displayTitle(for text: String, bundle: Bundle) -> String {
        guard self == .automatic else { return title(bundle: bundle) }
        if text.isEmpty { return title(bundle: bundle) }
        guard let detected = CodeSyntaxEngine.shared.cachedLanguage(text) else {
            return String(localized: "Detecting…", bundle: bundle)
        }
        return detected == .plain ? String(localized: "Auto · Unknown", bundle: bundle)
            : String(localized: "Auto · \(detected.title(bundle: bundle))", bundle: bundle)
    }
}

struct NoteTextMark: Codable, Equatable, Sendable {
    var location: Int
    var length: Int
    var bold = false
    var italic = false
    var code = false
    var strikethrough = false
    var link: String?

    enum CodingKeys: String, CodingKey { case location, length, bold, italic, code, strikethrough, link }

    init(location: Int, length: Int, bold: Bool = false, italic: Bool = false,
         code: Bool = false, strikethrough: Bool = false, link: String? = nil) {
        self.location = location; self.length = length; self.bold = bold; self.italic = italic
        self.code = code; self.strikethrough = strikethrough; self.link = link
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        location = try values.decode(Int.self, forKey: .location)
        length = try values.decode(Int.self, forKey: .length)
        bold = try values.decodeIfPresent(Bool.self, forKey: .bold) ?? false
        italic = try values.decodeIfPresent(Bool.self, forKey: .italic) ?? false
        code = try values.decodeIfPresent(Bool.self, forKey: .code) ?? false
        strikethrough = try values.decodeIfPresent(Bool.self, forKey: .strikethrough) ?? false
        link = try values.decodeIfPresent(String.self, forKey: .link)
    }

    var hasStyle: Bool { bold || italic || code || strikethrough || link != nil }

    func hasSameStyle(as other: Self) -> Bool {
        bold == other.bold && italic == other.italic && code == other.code &&
        strikethrough == other.strikethrough && link == other.link
    }

    func clipped(to range: NSRange) -> Self? {
        let intersection = NSIntersectionRange(NSRange(location: location, length: length), range)
        guard intersection.length > 0 else { return nil }
        var mark = self
        mark.location = intersection.location - range.location; mark.length = intersection.length
        return mark
    }

    var clickableURL: URL? {
        guard let link, let url = URL(string: link), let scheme = url.scheme?.lowercased(),
              ["https", "http", "mailto"].contains(scheme) else { return nil }
        return url
    }
}

struct NoteImage: Codable, Equatable, Sendable {
    var id: UUID
    var name: String
    var pixelWidth: Int
    var pixelHeight: Int
}

/// Rows and cells are document data; grid geometry and colors are only display.
struct NoteTable: Codable, Equatable, Sendable {
    var rows: [[String]] = Array(repeating: Array(repeating: "", count: 2), count: 3)

    var columnCount: Int { rows.first?.count ?? 0 }
    var plainText: String { rows.map { $0.joined(separator: "\t") }.joined(separator: "\n") }
    var isValid: Bool {
        !rows.isEmpty && columnCount > 0 && rows.allSatisfy { $0.count == columnCount }
    }
}

struct NoteBlock: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var kind: NoteBlockKind = .paragraph
    var text = ""
    var marks: [NoteTextMark] = []
    var isChecked = false
    var language: CodeLanguage = .plain
    var image: NoteImage?
    var table: NoteTable?

    init(id: UUID = UUID(), kind: NoteBlockKind = .paragraph, text: String = "", marks: [NoteTextMark] = [],
         isChecked: Bool = false, language: CodeLanguage? = nil, image: NoteImage? = nil, table: NoteTable? = nil) {
        self.id = id
        self.kind = kind
        self.text = text
        self.marks = marks
        self.isChecked = isChecked
        self.language = language ?? (kind == .code ? .automatic : .plain)
        self.image = image
        self.table = table ?? (kind == .table ? NoteTable() : nil)
    }

    var plainText: String { table?.plainText ?? image.map { "[\($0.name)]" } ?? (kind == .divider ? "---" : text) }
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
    var isEmpty: Bool { blocks.allSatisfy { $0.text.isEmpty && !$0.kind.isAttachment } }

    func listOrdinal(at index: Int) -> Int {
        guard blocks.indices.contains(index), blocks[index].kind == .orderedList else { return 1 }
        var first = index
        while first > 0 && blocks[first - 1].kind == .orderedList { first -= 1 }
        return index - first + 1
    }

    func validate() throws {
        guard schemaVersion == 1 else { throw NoteFileError.unsupportedVersion }
        guard !blocks.isEmpty, Set(blocks.map(\.id)).count == blocks.count else {
            throw NoteFileError.invalidContent
        }
        for block in blocks {
            if block.kind == .table {
                guard let table = block.table, table.isValid, block.text.isEmpty, block.marks.isEmpty else {
                    throw NoteFileError.invalidContent
                }
            } else if block.table != nil { throw NoteFileError.invalidContent }
            if block.kind == .divider && (!block.text.isEmpty || !block.marks.isEmpty) {
                throw NoteFileError.invalidContent
            }
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
