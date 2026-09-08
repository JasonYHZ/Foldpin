import Foundation

/// A single emoji grapheme, including flags, skin tones and joined families.
/// This is note presentation metadata, never a prefix inserted into the body.
nonisolated enum NoteIcon {
    static let suggestions = [
        "📝", "📌", "📚", "📋", "🗂️", "📅", "💡", "🎯",
        "✅", "⭐️", "❤️", "🔥", "🚀", "🔖", "💻", "🛠️",
        "🐛", "🧪", "🎨", "🎵", "📷", "🎬", "💬", "🔗",
        "🏠", "💼", "🎓", "🌍", "✈️", "☕️", "🍎", "🎁",
        "🌿", "🌸", "🌈", "☀️", "🌙", "🐱", "🐶", "😊"
    ]

    nonisolated static func normalized(_ input: String) -> String? {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.utf8.count <= 128, value.count == 1,
              let first = value.unicodeScalars.first,
              first.properties.isEmoji, !first.properties.isEmojiModifier else { return nil }
        let scalars = value.unicodeScalars
        // Digits, # and * have the Emoji property but only become emoji in a
        // keycap sequence. A lone regional indicator is not a complete flag.
        if first.value < 0x80 {
            guard scalars.last?.value == 0x20E3 else { return nil }
        }
        if (0x1F1E6...0x1F1FF).contains(first.value) {
            guard scalars.count == 2, scalars.allSatisfy({ (0x1F1E6...0x1F1FF).contains($0.value) }) else { return nil }
        }
        guard scalars.allSatisfy({ scalar in
            scalar.properties.isEmoji || scalar.value == 0x200D || scalar.value == 0xFE0F ||
                scalar.value == 0x20E3 || (0xE0020...0xE007F).contains(scalar.value)
        }) else { return nil }
        return value
    }
}
