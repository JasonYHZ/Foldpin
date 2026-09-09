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

    // Night paper keeps its warm hue at a lower luminance. Its ink remains
    // dark; the app's Dark Aqua appearance still owns menus and code themes.
    static let paperBackground = adaptive(0xFBF0C0, 0xB9AA89)
    static let paperText = adaptive(0x333626, 0x302A20)
    static let paperSecondaryText = paperText.withAlphaComponent(0.85)
    static let paperPlaceholderText = paperText.withAlphaComponent(0.84)
    static let paperLink = adaptive(0x245B88, 0x173E60)
    static let paperError = adaptive(0x902C22, 0x681E17)

    private static let paperColors: [NoteColor: NSColor] = [
        .yellow: adaptive(0xF6E5A8, 0xBFAE89),
        .green: adaptive(0xE0EACA, 0xAFB99D),
        .blue: adaptive(0xDDE9F2, 0xADB9C4),
        .pink: adaptive(0xF3DDE0, 0xC4AFB2),
        .purple: adaptive(0xEAE1F0, 0xBDB0C5)
    ]
    private static let glassColors: [NoteColor: NSColor] = [
        .yellow: adaptive(0xDEB14A, 0x9C7D38).withAlphaComponent(0.22),
        .green: adaptive(0x80A861, 0x5E8051).withAlphaComponent(0.22),
        .blue: adaptive(0x649ACA, 0x4F729E).withAlphaComponent(0.22),
        .pink: adaptive(0xCE8195, 0xA3667C).withAlphaComponent(0.22),
        .purple: adaptive(0xA48BC3, 0x8068A0).withAlphaComponent(0.22)
    ]
    private static let solidGlassColors: [NoteColor: NSColor] = [
        .yellow: adaptive(0xF3E9CD, 0x363127),
        .green: adaptive(0xE4EBD9, 0x2C332A),
        .blue: adaptive(0xE2EAF2, 0x29313B),
        .pink: adaptive(0xF1E2E5, 0x382C32),
        .purple: adaptive(0xEAE3F0, 0x322D3B)
    ]

    static func paperBackground(for color: NoteColor) -> NSColor {
        paperColors[color] ?? paperBackground
    }

    static func glassTint(for color: NoteColor) -> NSColor? { glassColors[color] }

    /// The reading fill is ordinary content, so the selected paper color stays
    /// visible even when the system de-emphasizes an inactive glass window.
    static func glassReadingTint(for color: NoteColor) -> NSColor? {
        glassColors[color]?.withAlphaComponent(0.18)
    }

    static func solidGlassBackground(for color: NoteColor) -> NSColor {
        solidGlassColors[color] ?? .windowBackgroundColor
    }

    @MainActor static func colorSwatch(for color: NoteColor) -> NSImage {
        let image = NSImage(size: NSSize(width: 14, height: 14), flipped: false) { bounds in
            let path = NSBezierPath(ovalIn: bounds.insetBy(dx: 1, dy: 1))
            paperBackground(for: color).setFill()
            path.fill()
            NSColor.labelColor.withAlphaComponent(0.35).setStroke()
            path.lineWidth = 0.5
            path.stroke()
            return true
        }
        image.isTemplate = false
        return image
    }

    // The codec already receives the surface's ink. Keep secondary roles on
    // that same surface, instead of inheriting white labels from Dark Aqua.
    static func secondaryText(for ink: NSColor) -> NSColor {
        ink == paperText ? paperSecondaryText : .secondaryLabelColor
    }

    static func placeholderText(for ink: NSColor) -> NSColor {
        ink == paperText ? paperPlaceholderText : .placeholderTextColor
    }

    static func linkText(for ink: NSColor) -> NSColor {
        ink == paperText ? paperLink : .linkColor
    }

    @MainActor static func rule(for ink: NSColor) -> NSColor {
        guard ink == paperText else { return .separatorColor }
        return ink.withAlphaComponent(NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast ? 0.7 : 0.28)
    }

    static func inlineCodeBackground(for ink: NSColor) -> NSColor {
        ink == paperText ? ink.withAlphaComponent(0.08) : NSColor.quaternaryLabelColor.withAlphaComponent(0.1)
    }
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
