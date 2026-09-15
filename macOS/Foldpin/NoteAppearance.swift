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
    @ObservedObject private var style = NoteStyleSettings.shared
    var appearance: NoteAppearance
    var cornerRadius: CGFloat = 16
    var color: NoteColor = .original
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    private var usesGlass: Bool {
        appearance == .translucent && !reduceTransparency && contrast != .increased
    }

    func body(content: Content) -> some View {
        content
            .background { NoteSheetFill(appearance: appearance, color: color) }
            .clipShape(.rect(cornerRadius: cornerRadius))
            .glassEffect(usesGlass ? (style.values.clearGlass ? Glass.clear : Glass.regular).tint(NotePalette.glassTint(for: color).map { Color(nsColor: $0) }) : .identity, in: .rect(cornerRadius: cornerRadius))
    }
}

struct NoteSheetFill: View {
    var drawsPaper = true
    @ObservedObject private var style = NoteStyleSettings.shared
    var appearance: NoteAppearance
    var color: NoteColor = .original
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        if appearance == .paper {
            Color(nsColor: NotePalette.paperBackground(for: color))
                .opacity(drawsPaper ? (reduceTransparency || contrast == .increased ? 1 : style.values.paperOpacity) : 0)
        } else {
            if reduceTransparency || contrast == .increased {
                Color(nsColor: NotePalette.solidGlassBackground(for: color))
            } else {
                // Glass supplies adaptive blur; this independently adjusts
                // the reading tint without fading text or controls.
                Color(nsColor: .textBackgroundColor)
                    .opacity(style.values.glassOpacity)
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
