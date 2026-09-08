import AppKit

enum NotePalette {
    static func adaptive(_ light: UInt32, _ dark: UInt32) -> NSColor {
        NSColor(name: nil) { appearance in
            let value = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat((value >> 16) & 255) / 255,
                           green: CGFloat((value >> 8) & 255) / 255,
                           blue: CGFloat(value & 255) / 255, alpha: 1)
        }
    }

    static let paperBackground = adaptive(0xFBF0C0, 0x292824)
    static let paperText = adaptive(0x333626, 0xE8E2D5)
    static let edgeBackground = adaptive(0xF7FAF0, 0x282C25)
    static let edgeText = adaptive(0x636E4F, 0xC7D2B7)
}

/// Native adaptation of GitHub's light/dark syntax palette; see
/// ThirdPartyNotices.txt. These are display colors, never document metadata.
@MainActor enum GitHubCodeTheme {
    static var background: NSColor { NativeCodeTheme.github.background }
    static var border: NSColor { NativeCodeTheme.github.border }
    static var foreground: NSColor { NativeCodeTheme.github.foreground }
    static var comment: NSColor { NativeCodeTheme.github.token(.comment, language: .javascript).foreground }
    static var keyword: NSColor { NativeCodeTheme.github.token(.keyword, language: .javascript).foreground }
    static var string: NSColor { NativeCodeTheme.github.token(.string, language: .javascript).foreground }
    static var constant: NSColor { NativeCodeTheme.github.token(.constant, language: .javascript).foreground }
    static var function: NSColor { NativeCodeTheme.github.token(.function, language: .javascript).foreground }
}
