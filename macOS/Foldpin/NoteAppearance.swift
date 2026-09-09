import SwiftUI
import AppKit

enum NoteAppearance: String, CaseIterable, Identifiable {
    case paper
    case translucent

    static let preferenceKey = "noteAppearance"
    static let paperColor = Color(nsColor: NotePalette.paperBackground)
    var textColor: NSColor { self == .paper ? NotePalette.paperText : .labelColor }
    var secondaryTextColor: NSColor { NotePalette.secondaryText(for: textColor) }
    var id: String { rawValue }
    func title(bundle: Bundle) -> String {
        self == .paper ? String(localized: "Paper", bundle: bundle) : String(localized: "Glass", bundle: bundle)
    }
    func subtitle(bundle: Bundle) -> String {
        self == .paper
            ? String(localized: "A warm surface for focused writing", bundle: bundle)
            : String(localized: "Soft glass with desktop colors", bundle: bundle)
    }
}

/// Apply one glass surface to the whole note. Keep the modifier in place in
/// both modes so switching material never replaces the native text editor.
struct NoteSheetSurface: ViewModifier {
    var appearance: NoteAppearance
    var cornerRadius: CGFloat = 16
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    private var usesGlass: Bool {
        appearance == .translucent && !reduceTransparency && contrast != .increased
    }

    func body(content: Content) -> some View {
        content
            .background { NoteSheetFill(appearance: appearance) }
            .clipShape(.rect(cornerRadius: cornerRadius))
            .glassEffect(usesGlass ? .regular : .identity, in: .rect(cornerRadius: cornerRadius))
    }
}

struct NoteSheetFill: View {
    var appearance: NoteAppearance
    var color: NoteColor = .original
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if appearance == .paper {
            Color(nsColor: NotePalette.paperBackground(for: color))
        } else {
            if reduceTransparency || contrast == .increased {
                Color(nsColor: NotePalette.solidGlassBackground(for: color))
            } else {
                // Regular glass supplies adaptive blur and contrast. Keep only
                // a light reading tint so its material remains visible.
                (colorScheme == .dark ? Color.black : Color.white)
                    .opacity(colorScheme == .dark ? 0.16 : 0.12)
                    .overlay {
                        // A persistent color wash inside the existing glass
                        // content survives the system's inactive-window tint.
                        if let tint = NotePalette.glassReadingTint(for: color) {
                            Color(nsColor: tint)
                        }
                    }
            }
        }
    }
}

struct NoteControlSurface: ViewModifier {
    var appearance: NoteAppearance
    var cornerRadius: CGFloat = 10
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    @ViewBuilder func body(content: Content) -> some View {
        if appearance == .translucent {
            if reduceTransparency || contrast == .increased {
                content.background(Color(nsColor: .controlBackgroundColor), in: .rect(cornerRadius: cornerRadius))
                    .overlay(RoundedRectangle(cornerRadius: cornerRadius).strokeBorder(.primary.opacity(0.3)))
            } else {
                content.glassEffect(.regular.interactive(), in: .rect(cornerRadius: cornerRadius))
            }
        } else {
            content
        }
    }
}
