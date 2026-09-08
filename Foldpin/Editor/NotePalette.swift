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
enum GitHubCodeTheme {
    static let background = NotePalette.adaptive(0xF6F8FA, 0x161B22)
    static let border = NotePalette.adaptive(0xD0D7DE, 0x30363D)
    static let foreground = NotePalette.adaptive(0x1F2328, 0xE6EDF3)
    static let comment = NotePalette.adaptive(0x656D76, 0x8B949E)
    static let keyword = NotePalette.adaptive(0xCF222E, 0xFF7B72)
    static let string = NotePalette.adaptive(0x0A3069, 0xA5D6FF)
    static let constant = NotePalette.adaptive(0x0550AE, 0x79C0FF)
    static let function = NotePalette.adaptive(0x8250DF, 0xD2A8FF)
}
