import AppKit
import Combine
import CryptoKit

@MainActor
final class CodeThemeSettings: ObservableObject {
    struct Choice: Identifiable {
        let id: String
        let name: String
        let theme: NativeCodeTheme
        let imported: Bool
    }
    static let shared = CodeThemeSettings()
    static let preferenceKey = "codeTheme"
    static let didChange = Notification.Name("FoldpinCodeThemeDidChange")
    static let backgroundOpacityKey = "codeBackgroundOpacity"
    static let backgroundOpacityDidChange = Notification.Name("FoldpinCodeBackgroundOpacityDidChange")
    @Published private(set) var choices: [Choice] = []
    @Published private(set) var selection: String
    @Published private(set) var backgroundOpacity: Double
    private let defaults: UserDefaults
    let directory: URL
    var theme: NativeCodeTheme { choices.first { $0.id == selection }?.theme ?? .github }
    var selectedIsImported: Bool { choices.first { $0.id == selection }?.imported == true }

    init(defaults: UserDefaults = .standard, directory: URL? = nil) {
        self.defaults = defaults
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Foldpin/CodeThemes", isDirectory: true)
        selection = defaults.string(forKey: Self.preferenceKey) ?? "github"
        backgroundOpacity = Self.normalizedOpacity((defaults.object(forKey: Self.backgroundOpacityKey) as? NSNumber)?.doubleValue ?? 1)
        choices = [Choice(id: "github", name: "GitHub", theme: .github, imported: false)]
        #if SWIFT_PACKAGE
        let resources = Bundle.module
        #else
        let resources = Bundle.main
        #endif
        for (id, name) in [("light_plus", "VS Code Light+"), ("dark_plus", "VS Code Dark+"),
                           ("monokai-color-theme", "Monokai"), ("solarized-light-color-theme", "Solarized Light"),
                           ("solarized-dark-color-theme", "Solarized Dark")] {
            if let url = resources.url(forResource: id, withExtension: "json", subdirectory: "CodeThemes") ?? resources.url(forResource: id, withExtension: "json"),
               let definition = try? CodeThemeLoader.load(url, allowedDirectory: url.deletingLastPathComponent()) {
                choices.append(Choice(id: id, name: name, theme: NativeCodeTheme(light: definition), imported: false))
            }
        }
        if let files = try? FileManager.default.contentsOfDirectory(at: self.directory, includingPropertiesForKeys: nil) {
            for url in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) where Self.isImportedID(url.deletingPathExtension().lastPathComponent) && url.pathExtension == "json" {
                if let definition = try? CodeThemeLoader.load(url) {
                    choices.append(Choice(id: url.deletingPathExtension().lastPathComponent, name: definition.name,
                                          theme: NativeCodeTheme(light: definition), imported: true))
                }
            }
        }
        if !choices.contains(where: { $0.id == selection }) { selection = "github" }
    }

    func select(_ id: String) {
        guard id != selection, choices.contains(where: { $0.id == id }) else { return }
        selection = id
        defaults.set(id, forKey: Self.preferenceKey)
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    func setBackgroundOpacity(_ value: Double) {
        let opacity = Self.normalizedOpacity(value)
        guard opacity != backgroundOpacity else { return }
        backgroundOpacity = opacity
        defaults.set(opacity, forKey: Self.backgroundOpacityKey)
        // Painting only: do not reapply text attributes or schedule syntax work.
        NotificationCenter.default.post(name: Self.backgroundOpacityDidChange, object: self)
    }

    private static func normalizedOpacity(_ value: Double) -> Double {
        value.isFinite ? min(1, max(0, value)) : 1
    }

    func install(_ definition: CodeThemeDefinition) throws {
        let data = try definition.standardJSON()
        let id = "import-" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: directory.appendingPathComponent(id + ".json"), options: .atomic)
        } catch { throw CodeThemeError.storage }
        if !choices.contains(where: { $0.id == id }) {
            choices.append(Choice(id: id, name: definition.name, theme: NativeCodeTheme(light: definition), imported: true))
        }
        select(id)
    }

    func removeSelectedImport() throws {
        guard selectedIsImported, Self.isImportedID(selection) else { return }
        let removed = selection
        do { try FileManager.default.removeItem(at: directory.appendingPathComponent(removed + ".json")) }
        catch { throw CodeThemeError.storage }
        select("github")
        choices.removeAll { $0.id == removed }
    }

    private static func isImportedID(_ id: String) -> Bool {
        id.hasPrefix("import-") && id.count == 71 && id.dropFirst(7).allSatisfy { $0.isASCII && $0.isHexDigit }
    }
}
