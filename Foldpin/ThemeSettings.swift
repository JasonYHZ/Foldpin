import AppKit
import Combine

enum AppTheme: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }

    func title(bundle: Bundle) -> String {
        switch self {
        case .system: String(localized: "Follow System", bundle: bundle)
        case .light: String(localized: "Light", bundle: bundle)
        case .dark: String(localized: "Dark", bundle: bundle)
        }
    }

    var appearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

@MainActor
final class ThemeSettings: ObservableObject {
    static let shared = ThemeSettings()
    static let preferenceKey = "appTheme"
    @Published private(set) var selection: AppTheme
    private let defaults: UserDefaults
    private let applyAppearance: @MainActor (NSAppearance?) -> Void

    init(defaults: UserDefaults = .standard,
         applyAppearance: @escaping @MainActor (NSAppearance?) -> Void = { NSApp.appearance = $0 }) {
        self.defaults = defaults
        self.applyAppearance = applyAppearance
        selection = AppTheme(rawValue: defaults.string(forKey: Self.preferenceKey) ?? "") ?? .system
    }

    func apply() { applyAppearance(selection.appearance) }

    func select(_ theme: AppTheme) {
        if theme != selection {
            if theme == .system { defaults.removeObject(forKey: Self.preferenceKey) }
            else { defaults.set(theme.rawValue, forKey: Self.preferenceKey) }
            selection = theme
        }
        // nil removes the app override, so subsequent system changes propagate
        // naturally to existing windows, SwiftUI hosts and native text views.
        apply()
    }
}
