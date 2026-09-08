import Foundation
import Testing
@testable import FoldpinCore

@Test func noteEmojiGridCategoryMovesMonotonicallyAcrossFastScrollsAndJumps() throws {
    let grid = NoteEmojiGridLayout.browsing
    let order = NoteEmojiCategory.allCases
    for step: CGFloat in [1, 37, 281, 1500] {
        var last = 0
        for y in stride(from: CGFloat(-100), through: grid.contentHeight + 300, by: step) {
            let category = try #require(grid.category(at: y))
            let current = try #require(order.firstIndex(of: category))
            #expect(current >= last)
            last = current
        }
        last = order.count - 1
        for y in stride(from: grid.contentHeight + 300, through: CGFloat(-100), by: -step) {
            let category = try #require(grid.category(at: y))
            let current = try #require(order.firstIndex(of: category))
            #expect(current <= last)
            last = current
        }
    }
    // Distant jumps and revisits must not depend on callbacks from prior groups.
    for category in [.flags, .common, .nature, .people, .objects, .smileys] as [NoteEmojiCategory] {
        let id = try #require(grid.sectionID(for: category))
        let row = try #require(grid.rows.firstIndex(where: { $0.id == id }))
        let y = NoteEmojiGridLayout.topInset + CGFloat(row) * NoteEmojiGridLayout.rowHeight
        #expect(grid.category(at: y) == category)
        #expect(grid.category(at: y) == category)
    }
    #expect(grid.category(at: -300) == .common)
    #expect(grid.category(at: grid.contentHeight + 300) == .flags)
}

@Test func noteEmojiGridKeepsAllChoicesAndDistinctKeyboardAnchors() throws {
    let grid = NoteEmojiGridLayout.browsing
    let items = grid.rows.flatMap(\.items)
    #expect(items.count == NoteEmojiCatalog.shared.entries.count + 40)
    #expect(Set(items.map(\.id)).count == items.count)
    #expect(Set(grid.rows.map(\.id)).count == grid.rows.count)
    #expect(grid.rows.allSatisfy { $0.items.count <= NoteEmojiGridLayout.columns })
    // Keyboard traversal reaches every entry, including across category headers.
    for (index, item) in items.enumerated() {
        #expect(grid.neighbor(of: item.id, direction: .left)?.id == (index > 0 ? items[index - 1].id : nil))
        #expect(grid.neighbor(of: item.id, direction: .right)?.id == (index + 1 < items.count ? items[index + 1].id : nil))
        let rowID = try #require(grid.rowID(for: item))
        #expect(grid.rows.contains { $0.id == rowID && $0.items.contains { $0.id == item.id } })
    }
    let finalSmileys = try #require(grid.rows.last(where: { $0.category == .smileys && !$0.items.isEmpty }))
    let firstPeople = try #require(grid.rows.first(where: { $0.category == .people && !$0.items.isEmpty }))
    #expect(grid.neighbor(of: finalSmileys.items.last!.id, direction: .down)?.id
            == firstPeople.items[finalSmileys.items.count - 1].id)
}

@Test func noteEmojiGridSearchClearsCategoryAndRetainsCustomEmoji() throws {
    for query in ["电脑", "LAPTOP", "👩🏽‍💻", "no-such-emoji-927"] {
        let grid = NoteEmojiGridLayout(query: query)
        #expect(grid.category(at: 0) == nil)
        #expect(grid.category(at: 5000) == nil)
        #expect(grid.sectionID(for: .common) == nil)
        #expect(grid.rows.flatMap(\.items).map { $0.entry.emoji }
                == NoteEmojiCatalog.shared.matches(category: .common, query: query).map(\.emoji))
    }
    #expect(NoteEmojiGridLayout(query: " ").rows.count == NoteEmojiGridLayout.browsing.rows.count)
}
