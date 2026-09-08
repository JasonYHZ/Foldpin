import Foundation

/// Every heading and emoji row has the same, explicit height. A single lazy
/// stack can therefore locate distant sections without revising estimated
/// group heights while scrolling. It also provides one source of category truth.
nonisolated struct NoteEmojiGridLayout: Sendable {
    static let columns = 10
    static let rowHeight: CGFloat = 36
    static let topInset: CGFloat = 4
    static let bottomInset: CGFloat = 12
    static let browsing = NoteEmojiGridLayout(query: "")

    struct Item: Identifiable, Sendable {
        let id: String
        let entry: NoteEmoji
    }

    struct Row: Identifiable, Sendable {
        enum Kind: Sendable { case heading, emoji, empty }
        let id: String
        let category: NoteEmojiCategory?
        let kind: Kind
        let items: [Item]
    }

    enum Direction { case left, right, up, down }
    private struct Location: Sendable { let row: Int; let column: Int }

    let rows: [Row]
    let firstItem: Item?
    private let locations: [String: Location]
    private let sectionRows: [NoteEmojiCategory: Int]
    var contentHeight: CGFloat { Self.topInset + CGFloat(rows.count) * Self.rowHeight + Self.bottomInset }

    init(query: String, catalog: NoteEmojiCatalog = .shared) {
        let isSearching = !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let categories: [NoteEmojiCategory?] = isSearching ? [nil] : NoteEmojiCategory.allCases.map { $0 }
        var rows: [Row] = []
        var locations: [String: Location] = [:]
        var sectionRows: [NoteEmojiCategory: Int] = [:]
        for category in categories {
            let group = category?.rawValue ?? "search"
            if let category { sectionRows[category] = rows.count }
            rows.append(Row(id: "section/\(group)", category: category, kind: .heading, items: []))
            let entries = catalog.matches(category: category ?? .common, query: query)
            for start in stride(from: 0, to: entries.count, by: Self.columns) {
                let items = entries[start..<min(start + Self.columns, entries.count)].map {
                    Item(id: "emoji/\(group)/\($0.id)", entry: $0)
                }
                for (column, item) in items.enumerated() {
                    locations[item.id] = Location(row: rows.count, column: column)
                }
                rows.append(Row(id: "row/\(group)/\(start)", category: category, kind: .emoji, items: items))
            }
            if entries.isEmpty { rows.append(Row(id: "empty/\(group)", category: category, kind: .empty, items: [])) }
        }
        self.rows = rows
        self.firstItem = rows.first(where: { !$0.items.isEmpty })?.items.first
        self.locations = locations
        self.sectionRows = sectionRows
    }

    func category(at visibleTop: CGFloat) -> NoteEmojiCategory? {
        guard !rows.isEmpty else { return nil }
        let top = visibleTop.isFinite ? visibleTop : 0
        let index = Int(min(max(0, (top + 8 - Self.topInset) / Self.rowHeight), CGFloat(rows.count - 1)))
        return rows[index].category
    }

    func sectionID(for category: NoteEmojiCategory) -> String? {
        sectionRows[category].map { rows[$0].id }
    }

    func rowID(for item: Item) -> String? { locations[item.id].map { rows[$0.row].id } }

    func neighbor(of id: String, direction: Direction) -> Item? {
        guard let position = locations[id] else { return nil }
        let items = rows[position.row].items
        if direction == .left, position.column > 0 { return items[position.column - 1] }
        if direction == .right, position.column + 1 < items.count { return items[position.column + 1] }
        let backwards = direction == .left || direction == .up
        var row = position.row + (backwards ? -1 : 1)
        while rows.indices.contains(row) {
            let adjacent = rows[row].items
            if !adjacent.isEmpty {
                switch direction {
                case .left: return adjacent.last
                case .right: return adjacent.first
                case .up, .down: return adjacent[min(position.column, adjacent.count - 1)]
                }
            }
            row += backwards ? -1 : 1
        }
        return nil
    }
}
