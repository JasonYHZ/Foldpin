import Foundation

nonisolated enum NoteEmojiCategory: String, CaseIterable, Decodable, Sendable {
    case common, smileys, people, nature, food, travel, activities, objects, symbols, flags

    var symbol: String {
        switch self {
        case .common: "star"
        case .smileys: "face.smiling"
        case .people: "hand.raised"
        case .nature: "leaf"
        case .food: "carrot"
        case .travel: "airplane"
        case .activities: "soccerball"
        case .objects: "lightbulb"
        case .symbols: "checkmark.circle"
        case .flags: "flag"
        }
    }

    func title(bundle: Bundle) -> String {
        switch self {
        case .common: String(localized: "Common Emoji", bundle: bundle)
        case .smileys: String(localized: "Smileys & Emotion", bundle: bundle)
        case .people: String(localized: "People & Body", bundle: bundle)
        case .nature: String(localized: "Animals & Nature", bundle: bundle)
        case .food: String(localized: "Food & Drink", bundle: bundle)
        case .travel: String(localized: "Travel & Places", bundle: bundle)
        case .activities: String(localized: "Activities", bundle: bundle)
        case .objects: String(localized: "Objects", bundle: bundle)
        case .symbols: String(localized: "Symbols", bundle: bundle)
        case .flags: String(localized: "Flags", bundle: bundle)
        }
    }
}

nonisolated struct NoteEmoji: Decodable, Identifiable, Sendable {
    let emoji: String
    let category: NoteEmojiCategory
    let name: String
    let chineseName: String
    // Fold names/keywords once when the shared catalog loads, not on every key.
    let searchText: String
    var id: String { emoji }

    init(emoji: String, category: NoteEmojiCategory = .common, name: String = "",
         chineseName: String = "", keywords: String = "") {
        self.emoji = emoji
        self.category = category
        self.name = name.isEmpty ? emoji : name
        self.chineseName = chineseName
        searchText = NoteEmojiCatalog.searchKey("\(name) \(chineseName) \(keywords)")
    }

    private enum CodingKeys: String, CodingKey { case emoji, category, name, chineseName, keywords }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(emoji: try values.decode(String.self, forKey: .emoji),
                  category: try values.decode(NoteEmojiCategory.self, forKey: .category),
                  name: try values.decode(String.self, forKey: .name),
                  chineseName: try values.decode(String.self, forKey: .chineseName),
                  keywords: try values.decode(String.self, forKey: .keywords))
    }

    func title(chinese: Bool) -> String { chinese && !chineseName.isEmpty ? chineseName : name }
}

/// One immutable, lazily loaded catalog shared by all note windows. There is
/// no network lookup, per-note resource copy, or web rendering.
nonisolated struct NoteEmojiCatalog: Sendable {
    static let shared: NoteEmojiCatalog = {
        #if SWIFT_PACKAGE
        let bundle = Bundle.module
        #else
        let bundle = Bundle.main
        #endif
        let url = bundle.url(forResource: "emoji-catalog", withExtension: "json", subdirectory: "EmojiResources")
            ?? bundle.url(forResource: "emoji-catalog", withExtension: "json")
        let entries = url.flatMap { try? Data(contentsOf: $0) }
            .flatMap { try? JSONDecoder().decode([NoteEmoji].self, from: $0) }
            ?? NoteIcon.suggestions.map { NoteEmoji(emoji: $0) }
        return NoteEmojiCatalog(entries: entries)
    }()

    let entries: [NoteEmoji]
    private let byCategory: [NoteEmojiCategory: [NoteEmoji]]
    private let byEmoji: [String: NoteEmoji]

    init(entries: [NoteEmoji]) {
        self.entries = entries
        let lookup = Dictionary(entries.map { (Self.emojiKey($0.emoji), $0) }, uniquingKeysWith: { first, _ in first })
        byEmoji = lookup
        var groups = Dictionary(grouping: entries, by: \.category)
        groups[.common] = NoteIcon.suggestions.map { lookup[Self.emojiKey($0)] ?? NoteEmoji(emoji: $0) }
        byCategory = groups
    }

    func matches(category: NoteEmojiCategory, query: String) -> [NoteEmoji] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return byCategory[category] ?? [] }
        if let emoji = NoteIcon.normalized(query) {
            return [byEmoji[Self.emojiKey(emoji)] ?? NoteEmoji(emoji: emoji)]
        }
        let terms = Self.searchKey(query).split(whereSeparator: \.isWhitespace).map(String.init)
        guard !terms.isEmpty else { return [] }
        // A search spans every category, including when Common is selected.
        return entries.filter { entry in terms.allSatisfy { entry.searchText.contains($0) } }
    }

    static func emojiKey(_ value: String) -> String { value.replacingOccurrences(of: "\u{FE0F}", with: "") }

    static func searchKey(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                      locale: Locale(identifier: "en_US_POSIX"))
    }
}
