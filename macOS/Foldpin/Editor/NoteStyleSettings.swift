import AppKit
import Combine

/// Local presentation only: never encoded in a note or added to its undo history.
struct NoteTypography: Codable, Equatable, Hashable {
    var bodyFamily = ""
    var codeFamily = ""
    var bodySize = 15.0
    var codeSize = 13.0
    var lineSpacing = 3.0

    init() {}
    private enum CodingKeys: String, CodingKey { case bodyFamily, codeFamily, bodySize, codeSize, lineSpacing }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        bodyFamily = (try? c.decode(String.self, forKey: .bodyFamily)) ?? ""
        codeFamily = (try? c.decode(String.self, forKey: .codeFamily)) ?? ""
        bodySize = (try? c.decode(Double.self, forKey: .bodySize)) ?? 15
        codeSize = (try? c.decode(Double.self, forKey: .codeSize)) ?? 13
        lineSpacing = (try? c.decode(Double.self, forKey: .lineSpacing)) ?? 3
    }
}

enum NoteTitlebarVisibility: String, Codable, CaseIterable, Identifiable {
    case automatic, alwaysVisible
    var id: Self { self }
}

enum NoteContentDensity: String, Codable, CaseIterable, Identifiable {
    case compact, standard, comfortable
    var id: Self { self }
    // Keep media, table cells, handles and the 52-point titlebar at their
    // established sizes. Only the surrounding spacing changes.
    var blockSpacing: CGFloat { switch self { case .compact: 5; case .standard: 9; case .comfortable: 15 } }
    var codeOuterSpacing: CGFloat { switch self { case .compact: 7; case .standard: 10; case .comfortable: 14 } }
    var editorVerticalInset: CGFloat { switch self { case .compact: 6; case .standard: 8; case .comfortable: 12 } }
    var footerTopInset: CGFloat { switch self { case .compact: 2; case .standard: 4; case .comfortable: 8 } }
    var footerBottomInset: CGFloat { switch self { case .compact: 6; case .standard: 8; case .comfortable: 12 } }
}

@MainActor enum NoteCreationLayout {
    static func frame(in visible: CGRect, offset: CGFloat = 0, preset: NoteNewSize) -> CGRect {
        let size = preset.size
        let proposed = CGRect(x: visible.maxX - size.width - 92 - offset,
                              y: visible.midY - size.height / 2 - offset,
                              width: size.width, height: size.height)
        return NoteFrame(proposed).fitted(to: [visible], fallback: visible,
                                           minimumSize: CGSize(width: NoteLayout.minimumWidth, height: NoteLayout.minimumExpandedHeight))
    }
}

struct NoteStylePreferences: Codable, Equatable {
    var typography = NoteTypography()
    var paperOpacity = 1.0
    /// Zero is the unmodified system glass. Negative values fade only the
    /// glass surface; positive values add a neutral reading fill behind ink.
    var glassBalance = 0.0
    var clearGlass = false
    var glassColorIntensity = 1.0
    var titlebarVisibility: NoteTitlebarVisibility = .automatic
    var contentDensity: NoteContentDensity = .standard
    var defaultNoteColor: NoteColor = .original
    var newNoteSize: NoteNewSize = .standard

    init() {}
    private enum CodingKeys: String, CodingKey {
        case typography, paperOpacity, glassBalance, glassOpacity, clearGlass, glassColorIntensity
        case titlebarVisibility, contentDensity, defaultNoteColor, newNoteSize
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        typography = (try? c.decode(NoteTypography.self, forKey: .typography)) ?? NoteTypography()
        paperOpacity = (try? c.decode(Double.self, forKey: .paperOpacity)) ?? 1
        glassBalance = (try? c.decode(Double.self, forKey: .glassBalance))
            ?? (try? c.decode(Double.self, forKey: .glassOpacity)) ?? 0
        clearGlass = (try? c.decode(Bool.self, forKey: .clearGlass)) ?? false
        glassColorIntensity = (try? c.decode(Double.self, forKey: .glassColorIntensity)) ?? 1
        titlebarVisibility = (try? c.decode(NoteTitlebarVisibility.self, forKey: .titlebarVisibility)) ?? .automatic
        contentDensity = (try? c.decode(NoteContentDensity.self, forKey: .contentDensity)) ?? .standard
        defaultNoteColor = (try? c.decode(NoteColor.self, forKey: .defaultNoteColor)) ?? .original
        newNoteSize = (try? c.decode(NoteNewSize.self, forKey: .newNoteSize)) ?? .standard
        normalize()
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(typography, forKey: .typography)
        try c.encode(paperOpacity, forKey: .paperOpacity)
        try c.encode(glassBalance, forKey: .glassBalance)
        try c.encode(clearGlass, forKey: .clearGlass)
        try c.encode(glassColorIntensity, forKey: .glassColorIntensity)
        try c.encode(titlebarVisibility, forKey: .titlebarVisibility)
        try c.encode(contentDensity, forKey: .contentDensity)
        try c.encode(defaultNoteColor, forKey: .defaultNoteColor)
        try c.encode(newNoteSize, forKey: .newNoteSize)
    }

    mutating func resetSurface() {
        let defaults = Self()
        paperOpacity = defaults.paperOpacity
        glassBalance = defaults.glassBalance
        clearGlass = defaults.clearGlass
        glassColorIntensity = defaults.glassColorIntensity
    }

    mutating func resetTitlebarAndDensity() {
        titlebarVisibility = .automatic
        contentDensity = .standard
    }

    mutating func resetBodyTypography() {
        typography.bodyFamily = ""
        typography.bodySize = 15
        typography.lineSpacing = 3
    }

    mutating func resetCodeTypography() {
        typography.codeFamily = ""
        typography.codeSize = 13
    }

    mutating func resetNewNoteDefaults() {
        defaultNoteColor = .original
        newNoteSize = .standard
    }

    mutating func normalize() {
        func clamp(_ value: Double, _ range: ClosedRange<Double>, fallback: Double) -> Double {
            value.isFinite ? min(range.upperBound, max(range.lowerBound, value)) : fallback
        }
        typography.bodySize = clamp(typography.bodySize, 11...28, fallback: 15)
        typography.codeSize = clamp(typography.codeSize, 10...24, fallback: 13)
        typography.lineSpacing = clamp(typography.lineSpacing, 0...12, fallback: 3)
        paperOpacity = clamp(paperOpacity, 0.2...1, fallback: 1)
        glassBalance = clamp(glassBalance, -1...1, fallback: 0)
        glassColorIntensity = clamp(glassColorIntensity, 0...1, fallback: 1)
    }

    var nativeGlassOpacity: Double { max(0, 1 + min(0, glassBalance)) }
    var readingBackdropOpacity: Double { max(0, glassBalance) }
}

@MainActor final class NoteStyleSettings: ObservableObject {
    static let shared = NoteStyleSettings()
    static let preferenceKey = "noteStyle.v1"
    static let didChange = Notification.Name("Foldpin.NoteStyleChanged")
    static let typographyDidChange = Notification.Name("Foldpin.NoteTypographyChanged")
    @Published private(set) var values: NoteStylePreferences
    private let defaults: UserDefaults
    private struct FontKey: Hashable { let family: String; let size: CGFloat; let weight: CGFloat; let code: Bool }
    private var fonts: [FontKey: NSFont] = [:]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        values = defaults.data(forKey: Self.preferenceKey)
            .flatMap { try? JSONDecoder().decode(NoteStylePreferences.self, from: $0) } ?? NoteStylePreferences()
        values.normalize()
    }
    func update(_ change: (inout NoteStylePreferences) -> Void) {
        var next = values
        change(&next)
        next.normalize()
        guard next != values, let data = try? JSONEncoder().encode(next) else { return }
        let typographyChanged = next.typography != values.typography
        let layoutChanged = typographyChanged || next.contentDensity != values.contentDensity
        if typographyChanged { fonts.removeAll(keepingCapacity: true) }
        values = next
        defaults.set(data, forKey: Self.preferenceKey)
        NotificationCenter.default.post(name: Self.didChange, object: self)
        if layoutChanged { NotificationCenter.default.post(name: Self.typographyDidChange, object: self) }
    }
    func bodyFont(size: CGFloat? = nil, weight: NSFont.Weight = .regular) -> NSFont {
        font(family: values.typography.bodyFamily, size: size ?? values.typography.bodySize, weight: weight, code: false)
    }
    func codeFont(size: CGFloat? = nil, weight: NSFont.Weight = .regular) -> NSFont {
        font(family: values.typography.codeFamily, size: size ?? values.typography.codeSize, weight: weight, code: true)
    }
    private func font(family: String, size: CGFloat, weight: NSFont.Weight, code: Bool) -> NSFont {
        let key = FontKey(family: family, size: size, weight: weight.rawValue, code: code)
        if let cached = fonts[key] { return cached }
        let fallback = code ? NSFont.monospacedSystemFont(ofSize: size, weight: weight) : NSFont.systemFont(ofSize: size, weight: weight)
        guard !family.isEmpty,
              let custom = NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: size) else { fonts[key] = fallback; return fallback }
        let result = weight == .regular ? custom : NSFontManager.shared.convert(custom, toHaveTrait: .boldFontMask)
        fonts[key] = result
        return result
    }
}
