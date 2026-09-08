import Foundation

nonisolated enum CodeThemeError: Error, Equatable {
    case invalid, tooLarge, companionFolderRequired, outsideFolder, includeCycle, noColors, storage

    func message(bundle: Bundle) -> String {
        switch self {
        case .invalid: String(localized: "This is not a supported VS Code or TextMate theme file.", bundle: bundle)
        case .tooLarge: String(localized: "The theme is too large. Use files under 2 MB and at most 16 companion files.", bundle: bundle)
        case .companionFolderRequired: String(localized: "This theme uses companion files. Select the folder containing the theme and its dependencies.", bundle: bundle)
        case .outsideFolder: String(localized: "A theme dependency is outside the selected folder. Select their common parent folder.", bundle: bundle)
        case .includeCycle: String(localized: "The theme contains a circular or overly deep file reference.", bundle: bundle)
        case .noColors: String(localized: "No supported code colors were found in this file.", bundle: bundle)
        case .storage: String(localized: "The theme could not be saved or removed. Your current style is unchanged.", bundle: bundle)
        }
    }
}

nonisolated struct ThemeScope: Codable, Sendable {
    let values: [String]
    init(_ values: [String]) { self.values = values }
    init(from decoder: Decoder) throws {
        let box = try decoder.singleValueContainer()
        if let value = try? box.decode(String.self) { values = [value] }
        else { values = try box.decode([String].self) }
    }
    func encode(to encoder: Encoder) throws {
        var box = encoder.singleValueContainer()
        try box.encode(values)
    }
}

nonisolated struct ThemeTokenSettings: Codable, Sendable {
    var foreground: String?
    var background: String?
    var fontStyle: String?
}

nonisolated struct ThemeTokenRule: Codable, Sendable {
    var scope: ThemeScope?
    var settings: ThemeTokenSettings
}

nonisolated enum ThemeTokenColors: Decodable {
    case rules([ThemeTokenRule]), file(String)
    init(from decoder: Decoder) throws {
        let box = try decoder.singleValueContainer()
        if let path = try? box.decode(String.self) { self = .file(path) }
        else { self = .rules(try box.decode([ThemeTokenRule].self)) }
    }
}

nonisolated private struct VSCodeThemeFile: Decodable {
    var name: String?
    var type: String?
    var include: String?
    var colors: [String: String?]?
    var tokenColors: ThemeTokenColors?
}

nonisolated private struct TextMateThemeFile: Decodable {
    var name: String?
    var settings: [ThemeTokenRule]
}

/// An in-memory adapter. Imports and saved copies use the existing VS Code
/// color-theme schema, not a Foldpin theme interchange format.
nonisolated struct CodeThemeDefinition: Sendable {
    var name: String
    var type: String?
    var colors: [String: String]
    var rules: [ThemeTokenRule]

    func color(_ key: String) -> String? {
        guard let value = colors[key], ThemeRGBA(value) != nil else { return nil }
        return value
    }

    var isDark: Bool {
        if let type { return type == "dark" || type == "hc" || type == "hcBlack" }
        if let hex = color("editor.background"), let color = ThemeRGBA(hex) {
            return 0.2126 * color.red + 0.7152 * color.green + 0.0722 * color.blue < 0.5
        }
        return true
    }

    func standardJSON() throws -> Data {
        struct Export: Encodable {
            let name: String
            let type: String
            let colors: [String: String]
            let tokenColors: [ThemeTokenRule]
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(Export(name: name, type: isDark ? "dark" : "light", colors: colors, tokenColors: rules))
    }
}

nonisolated struct ThemeRGBA: Sendable {
    let red: Double, green: Double, blue: Double, alpha: Double
    init?(_ hex: String) {
        guard hex.hasPrefix("#") else { return nil }
        var digits = String(hex.dropFirst())
        guard [3, 4, 6, 8].contains(digits.count), digits.allSatisfy({ $0.isASCII && $0.isHexDigit }) else { return nil }
        if digits.count <= 4 { digits = digits.map { "\($0)\($0)" }.joined() }
        if digits.count == 6 { digits += "ff" }
        guard let rgba = UInt32(digits, radix: 16) else { return nil }
        red = Double((rgba >> 24) & 255) / 255
        green = Double((rgba >> 16) & 255) / 255
        blue = Double((rgba >> 8) & 255) / 255
        alpha = Double(rgba & 255) / 255
    }
}

nonisolated enum CodeThemeLoader {
    static let maximumFileBytes = 2 * 1_024 * 1_024

    static func load(_ file: URL, allowedDirectory: URL? = nil) throws -> CodeThemeDefinition {
        var visited: Set<URL> = []
        var totalBytes = 0
        var filesRead = 0
        let root = allowedDirectory?.resolvingSymlinksInPath().standardizedFileURL

        func read(_ url: URL, depth: Int) throws -> CodeThemeDefinition {
            let url = url.resolvingSymlinksInPath().standardizedFileURL
            guard depth < 8, !visited.contains(url) else { throw CodeThemeError.includeCycle }
            if let root, !url.path.hasPrefix(root.path.hasSuffix("/") ? root.path : root.path + "/") {
                throw CodeThemeError.outsideFolder
            }
            visited.insert(url)
            defer { visited.remove(url) }
            filesRead += 1
            guard filesRead <= 16 else { throw CodeThemeError.tooLarge }
            let data: Data
            do {
                let values = try url.resourceValues(forKeys: [.isRegularFileKey])
                guard values.isRegularFile == true else { throw CodeThemeError.invalid }
                let handle = try FileHandle(forReadingFrom: url)
                defer { try? handle.close() }
                data = try handle.read(upToCount: maximumFileBytes + 1) ?? Data()
            } catch let error as CodeThemeError { throw error }
            catch { throw CodeThemeError.invalid }
            totalBytes += data.count
            guard data.count <= maximumFileBytes, totalBytes <= 8 * maximumFileBytes else { throw CodeThemeError.tooLarge }
            func dependency(_ path: String) throws -> CodeThemeDefinition {
                guard root != nil else { throw CodeThemeError.companionFolderRequired }
                guard !path.hasPrefix("/"), !path.hasPrefix("~"), !path.contains(":") else { throw CodeThemeError.outsideFolder }
                return try read(url.deletingLastPathComponent().appendingPathComponent(path), depth: depth + 1)
            }
            do {
                var result: CodeThemeDefinition
                if url.pathExtension.lowercased() == "tmtheme" {
                    let theme = try PropertyListDecoder().decode(TextMateThemeFile.self, from: data)
                    result = CodeThemeDefinition(name: theme.name ?? url.deletingPathExtension().lastPathComponent,
                                                 colors: [:], rules: theme.settings)
                } else {
                    let decoder = JSONDecoder()
                    decoder.allowsJSON5 = true // JSONC comments and trailing commas, including escaped strings.
                    let theme = try decoder.decode(VSCodeThemeFile.self, from: data)
                    result = try theme.include.map(dependency) ?? CodeThemeDefinition(name: "", colors: [:], rules: [])
                    result.name = theme.name ?? url.deletingPathExtension().lastPathComponent
                    result.type = theme.type ?? result.type
                    result.colors.merge((theme.colors ?? [:]).compactMapValues { $0 }) { _, child in child }
                    switch theme.tokenColors {
                    case .rules(let rules): result.rules += rules
                    case .file(let path): result.rules += try dependency(path).rules
                    case nil: break
                    }
                }
                // TextMate's unscoped settings supply the base editor colors.
                for rule in result.rules where rule.scope == nil || rule.scope?.values.allSatisfy({ $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) == true {
                    if let value = rule.settings.foreground, result.colors["editor.foreground"] == nil { result.colors["editor.foreground"] = value }
                    if let value = rule.settings.background, result.colors["editor.background"] == nil { result.colors["editor.background"] = value }
                }
                result.name = String(result.name.filter { !$0.isNewline && !$0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) }.prefix(100))
                if result.name.trimmingCharacters(in: .whitespaces).isEmpty { result.name = url.deletingPathExtension().lastPathComponent }
                return result
            } catch let error as CodeThemeError { throw error }
            catch { throw CodeThemeError.invalid }
        }
        let result = try read(file, depth: 0)
        guard result.color("editor.background") != nil || result.color("editor.foreground") != nil ||
                result.rules.contains(where: { $0.settings.foreground.flatMap(ThemeRGBA.init) != nil }) else { throw CodeThemeError.noColors }
        return result
    }
}
