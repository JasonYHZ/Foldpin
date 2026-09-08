import Foundation
import Testing
@testable import FoldpinCore

@Test func noteEmojiCatalogLoadsBundledChoicesAndEveryCategory() {
    let catalog = NoteEmojiCatalog.shared
    #expect(catalog.entries.count == 1906)
    #expect(Set(catalog.entries.map(\.id)).count == catalog.entries.count)
    for entry in catalog.entries { #expect(NoteIcon.normalized(entry.emoji) == entry.emoji) }
    for category in NoteEmojiCategory.allCases {
        #expect(!catalog.matches(category: category, query: "").isEmpty)
    }
    #expect(catalog.matches(category: .common, query: "").count == 40)
    #expect(catalog.matches(category: .food, query: "").allSatisfy { $0.category == .food })
}

@Test func noteEmojiCatalogSearchesBothLanguagesAcrossCategories() {
    let catalog = NoteEmojiCatalog.shared
    for query in ["laptop", "LAPTOP", "电脑", "ＰＣ", "  笔记本电脑  "] {
        #expect(catalog.matches(category: .food, query: query).contains { $0.emoji == "💻" })
    }
    #expect(catalog.matches(category: .common, query: "grinning face").contains { $0.emoji == "😀" })
    #expect(catalog.matches(category: .common, query: "彩虹").contains { $0.emoji == "🌈" })
    #expect(catalog.matches(category: .common, query: "not-a-real-query-927").isEmpty)
}

@Test func noteEmojiCatalogAcceptsCustomSequencesAndPresentationVariants() {
    let catalog = NoteEmojiCatalog.shared
    for emoji in ["👩🏽‍💻", "👨‍👩‍👧‍👦", "🇨🇳", "1️⃣"] {
        #expect(catalog.matches(category: .common, query: emoji).map(\.emoji) == [emoji])
    }
    let star = catalog.matches(category: .common, query: "⭐️")
    #expect(star.count == 1 && star[0].name == "star")
    #expect(catalog.matches(category: .common, query: "🌿📝").isEmpty)
    #expect(catalog.matches(category: .common, query: "🌿 work").isEmpty)
}
