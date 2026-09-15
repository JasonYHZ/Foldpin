import AppKit
import Combine

/// Local presentation only: never encoded in a note or added to its undo history.
struct NoteTypography: Codable, Equatable, Hashable {
    var bodyFamily = ""
    var codeFamily = ""
    var bodySize = 15.0
    var codeSize = 13.0
    var lineSpacing = 3.0
}

struct NoteStylePreferences: Codable, Equatable {
    var typography = NoteTypography()
    var paperOpacity = 1.0
    var glassOpacity = 0.14
    var clearGlass = false

    mutating func normalize() {
        func clamp(_ value: Double, _ range: ClosedRange<Double>, fallback: Double) -> Double {
            value.isFinite ? min(range.upperBound, max(range.lowerBound, value)) : fallback
        }
        typography.bodySize = clamp(typography.bodySize, 11...28, fallback: 15)
        typography.codeSize = clamp(typography.codeSize, 10...24, fallback: 13)
        typography.lineSpacing = clamp(typography.lineSpacing, 0...12, fallback: 3)
        paperOpacity = clamp(paperOpacity, 0.2...1, fallback: 1)
        glassOpacity = clamp(glassOpacity, 0...1, fallback: 0.14)
    }
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
        if typographyChanged { fonts.removeAll(keepingCapacity: true) }
        values = next
        defaults.set(data, forKey: Self.preferenceKey)
        NotificationCenter.default.post(name: Self.didChange, object: self)
        if typographyChanged { NotificationCenter.default.post(name: Self.typographyDidChange, object: self) }
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
