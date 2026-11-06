import Combine
import Foundation

enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case simplifiedChinese = "zh-Hans"
    case traditionalChinese = "zh-Hant"
    case english = "en"
    case japanese = "ja"
    case korean = "ko"
    case german = "de"
    case french = "fr"
    case spanish = "es"

    static var localizationIdentifiers: [String] {
        [AppLanguage.english.rawValue] + allCases.filter { $0 != .system && $0 != .english }.map(\.rawValue)
    }

    var id: String { rawValue }

    func title(bundle: Bundle) -> String {
        switch self {
        case .system: String(localized: "Follow System", bundle: bundle)
        // Autonyms remain recognizable in either interface language.
        case .simplifiedChinese: "简体中文"
        case .traditionalChinese: "繁體中文"
        case .english: "English"
        case .japanese: "日本語"
        case .korean: "한국어"
        case .german: "Deutsch"
        case .french: "Français"
        case .spanish: "Español"
        }
    }
}

@MainActor
final class LanguageSettings: ObservableObject {
    static let shared = LanguageSettings()
    private static let preferenceKey = "AppleLanguages"

    struct Configuration {
        let selection: AppLanguage
        let identifier: String
        let bundle: Bundle
    }

    @Published private(set) var configuration: Configuration
    private let defaults: UserDefaults
    private let applicationID: String
    private let resources: Bundle
    private let systemLanguages: () -> [String]

    var selection: AppLanguage { configuration.selection }
    var bundle: Bundle { configuration.bundle }
    var locale: Locale { Locale(identifier: configuration.identifier) }

    init(defaults: UserDefaults = .standard,
         applicationID: String = Bundle.main.bundleIdentifier ?? "dev.jasonyu.Foldpin",
         resources: Bundle = .main,
         systemLanguages: @escaping () -> [String] = {
             // Read the global domain explicitly: Locale.preferredLanguages can
             // include the app override we are replacing with "Follow System".
             UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)?["AppleLanguages"] as? [String] ?? ["en"]
         }) {
        self.defaults = defaults
        self.applicationID = applicationID
        self.resources = resources
        self.systemLanguages = systemLanguages
        let selection = Self.readSelection(defaults: defaults, applicationID: applicationID)
        configuration = Self.resolve(selection, resources: resources, systemLanguages: systemLanguages())
    }

    func refresh() {
        apply(Self.readSelection(defaults: defaults, applicationID: applicationID))
    }

    func select(_ language: AppLanguage) {
        if language != selection {
            // Keep native menus aligned on future launches as well. These writes
            // affect only Foldpin; no system-wide preference is changed.
            if language == .system {
                defaults.removeObject(forKey: Self.preferenceKey)
            } else {
                defaults.set([language.rawValue], forKey: Self.preferenceKey)
            }
        }
        apply(language)
    }

    private func apply(_ selection: AppLanguage) {
        let next = Self.resolve(selection, resources: resources, systemLanguages: systemLanguages())
        guard next.selection != configuration.selection || next.identifier != configuration.identifier else { return }
        configuration = next
    }

    private static func resolve(_ selection: AppLanguage, resources: Bundle, systemLanguages: [String]) -> Configuration {
        let preferences = selection == .system ? systemLanguages : [selection.rawValue]
        let identifier = Bundle.preferredLocalizations(from: AppLanguage.localizationIdentifiers, forPreferences: preferences).first ?? "en"
        // Choosing an lproj bundle avoids Bundle.main's launch-time language cache.
        let bundle = resources.url(forResource: identifier, withExtension: "lproj")
            .flatMap(Bundle.init(url:)) ?? resources
        return Configuration(selection: selection, identifier: identifier, bundle: bundle)
    }

    private static func readSelection(defaults: UserDefaults, applicationID: String) -> AppLanguage {
        guard let languages = defaults.persistentDomain(forName: applicationID)?[preferenceKey] as? [String],
              !languages.isEmpty else { return .system }
        let match = Bundle.preferredLocalizations(from: AppLanguage.localizationIdentifiers, forPreferences: languages).first
        return match.flatMap(AppLanguage.init(rawValue:)) ?? .system
    }
}
