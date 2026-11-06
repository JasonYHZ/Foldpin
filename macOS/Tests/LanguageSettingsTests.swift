import Foundation
import Testing
@testable import FoldpinCore

@Suite @MainActor struct LanguageSettingsTests {
    @Test func explicitLanguagesSwitchImmediatelyAndSurviveRestart() throws {
        let fixture = try LanguageFixture()
        defer { fixture.cleanUp() }
        let settings = fixture.settings(system: ["en-US"])
        #expect(settings.selection == .system)
        for language in AppLanguage.allCases where language != .system {
            settings.select(language)
            #expect(settings.selection == language)
            #expect(settings.configuration.identifier == language.rawValue)
            #expect(settings.bundle.localizedString(forKey: "Language probe", value: nil, table: nil) == language.rawValue)
            #expect(fixture.defaults.stringArray(forKey: "AppleLanguages") == [language.rawValue])
            let restarted = fixture.settings(system: ["en-US"])
            #expect(restarted.selection == language)
            #expect(restarted.configuration.identifier == language.rawValue)
        }
        #expect(Set(AppLanguage.localizationIdentifiers).count == 8)
        #expect(AppLanguage.french.title(bundle: fixture.bundle) == "Français")
        #expect(AppLanguage.traditionalChinese.title(bundle: fixture.bundle) == "繁體中文")
    }

    @Test func systemLanguageMatchesRegionAndScriptAndFallsBackToEnglish() throws {
        let fixture = try LanguageFixture()
        defer { fixture.cleanUp() }
        let cases: [(String, String)] = [
            ("zh-CN", "zh-Hans"), ("zh-TW", "zh-Hant"), ("zh-HK", "zh-Hant"),
            ("ja-JP", "ja"), ("ko-KR", "ko"), ("de-AT", "de"),
            ("fr-CA", "fr"), ("es-MX", "es"), ("en-GB", "en"), ("zz-ZZ", "en")
        ]
        for (system, expected) in cases {
            let settings = fixture.settings(system: [system])
            #expect(settings.selection == .system)
            #expect(settings.configuration.identifier == expected, Comment(rawValue: system))
            settings.select(.english)
            settings.select(.system)
            #expect(fixture.defaults.persistentDomain(forName: fixture.domain)?["AppleLanguages"] == nil)
            #expect(settings.configuration.identifier == expected)
        }
        #expect(fixture.settings(system: ["zz-ZZ", "ja-JP"]).configuration.identifier == "ja")
        #expect(fixture.settings(system: []).configuration.identifier == "en")
    }

    @Test func regionalSavedPreferenceAndRefreshUseTheSelectedLanguage() throws {
        let fixture = try LanguageFixture()
        defer { fixture.cleanUp() }
        fixture.defaults.set(["es-MX"], forKey: "AppleLanguages")
        let settings = fixture.settings(system: ["en"])
        #expect(settings.selection == .spanish)
        fixture.defaults.set(["zh-Hant-TW"], forKey: "AppleLanguages")
        settings.refresh()
        #expect(settings.selection == .traditionalChinese)
        #expect(settings.configuration.identifier == "zh-Hant")
        let operation = try #require(MCPRegistry.operations.first { $0.name == "foldpin_update_settings" })
        for language in AppLanguage.allCases {
            try operation.validate(["libraryId": "test", "idempotencyKey": "test", "expectedRevision": "test", "language": language.rawValue])
        }
        #expect(throws: MCPFailure.self) {
            try operation.validate(["libraryId": "test", "idempotencyKey": "test", "expectedRevision": "test", "language": "unsupported"])
        }
    }
}

@MainActor private struct LanguageFixture {
    let domain: String
    let root: URL
    let defaults: UserDefaults
    let bundle: Bundle

    init() throws {
        domain = "Foldpin.LanguageTests." + UUID().uuidString
        root = FileManager.default.temporaryDirectory.appendingPathComponent(domain + ".bundle")
        defaults = try #require(UserDefaults(suiteName: domain))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let info = ["CFBundleIdentifier": domain, "CFBundleDevelopmentRegion": "en"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: root.appendingPathComponent("Info.plist"))
        for identifier in AppLanguage.localizationIdentifiers {
            let folder = root.appendingPathComponent(identifier + ".lproj")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try PropertyListSerialization.data(fromPropertyList: ["Language probe": identifier], format: .xml, options: 0)
                .write(to: folder.appendingPathComponent("Localizable.strings"))
        }
        bundle = try #require(Bundle(url: root))
    }

    func settings(system: [String]) -> LanguageSettings {
        LanguageSettings(defaults: defaults, applicationID: domain, resources: bundle, systemLanguages: { system })
    }

    func cleanUp() {
        defaults.removePersistentDomain(forName: domain)
        try? FileManager.default.removeItem(at: root)
    }
}
