import AppKit

enum CodeToken: String, CaseIterable {
    case comment, string, keyword, constant, function, tag, attribute, punctuation, entity, type, annotation
    case variable, property, operatorSymbol, regexp, heading, insertion, deletion

    init?(highlightScope scope: String, language: CodeLanguage) {
        switch scope {
        case "comment", "doctag": self = .comment
        case "string", "char.escape": self = .string
        case "regexp": self = .regexp
        case "keyword": self = .keyword
        case "literal", "number": self = .constant
        case "symbol": self = language == .html ? .entity : .constant
        case "title.function", "title.function.invoke": self = .function
        case "title.class", "title.class.inherited", "type": self = .type
        case "built_in": self = language == .java ? .type : .function
        case "name": self = language == .html ? .tag : .function
        case "attr", "attribute": self = .attribute
        case "tag", "punctuation": self = .punctuation
        case "symbol.entity": self = .entity
        case "meta", "meta.prompt": self = language == .java ? .annotation : .keyword
        case "meta.keyword": self = .keyword
        case "meta.string": self = .string
        case "variable", "variable.language", "variable.constant", "template-variable": self = .variable
        case "property", "selector-attr", "selector-class", "selector-id", "selector-pseudo": self = .property
        case "selector-tag": self = .tag
        case "operator": self = .operatorSymbol
        case "section", "title": self = .heading
        case "addition": self = .insertion
        case "deletion": self = .deletion
        default: return nil // Container scopes such as params are not tokens.
        }
    }

    func scopes(language: CodeLanguage) -> [[String]] {
        let suffix: String
        switch language {
        case .javascript: suffix = "js"
        case .typescript: suffix = "ts"
        default: suffix = language.rawValue
        }
        let leaves: [String]
        switch self {
        case .comment: leaves = ["comment.line.double-slash", "comment.line.number-sign", "comment.block"]
        case .string: leaves = ["string.quoted.double", "string.quoted.single"]
        case .keyword: leaves = ["keyword.control", "storage.type", "storage.modifier"]
        case .constant: leaves = ["constant.numeric"]
        case .function: leaves = ["entity.name.function", "support.function"]
        case .tag: leaves = ["entity.name.tag"]
        case .attribute: leaves = language == .json ? ["support.type.property-name", "meta.structure.dictionary.key"] : ["entity.other.attribute-name"]
        case .punctuation: leaves = ["punctuation.definition.tag"]
        case .entity: leaves = ["constant.character.entity"]
        case .type: leaves = ["entity.name.type.class", "support.class"]
        case .annotation: leaves = ["storage.type.annotation", "entity.name.type.annotation"]
        case .variable: leaves = ["variable.other", "variable.language"]
        case .property: leaves = ["variable.other.property", "support.type.property-name"]
        case .operatorSymbol: leaves = ["keyword.operator"]
        case .regexp: leaves = ["string.regexp"]
        case .heading: leaves = ["markup.heading", "entity.name.section"]
        case .insertion: leaves = ["markup.inserted"]
        case .deletion: leaves = ["markup.deleted"]
        }
        return leaves.map { [language == .html ? "text.html.basic" : "source.\(suffix)", "\($0).\(suffix)"] }
    }
}

@MainActor
final class NativeCodeTheme {
    struct TokenStyle {
        let foreground: NSColor
        let fontStyle: String
    }
    let background: NSColor
    let border: NSColor
    let foreground: NSColor
    let caret: NSColor
    let selection: NSColor
    let selectionForeground: NSColor
    private let light: CodeThemeDefinition
    private let dark: CodeThemeDefinition
    private var tokens: [String: TokenStyle] = [:]
    private var tokenTypography = NoteTypography()
    private var tokenAttributes: [String: [NSAttributedString.Key: Any]] = [:]

    init(light: CodeThemeDefinition, dark: CodeThemeDefinition? = nil) {
        self.light = light
        self.dark = dark ?? light
        let second = dark ?? light
        func color(_ key: String, lightFallback: String, darkFallback: String) -> NSColor {
            Self.adaptive(light.color(key) ?? (light.isDark ? darkFallback : lightFallback),
                          second.color(key) ?? (second.isDark ? darkFallback : lightFallback))
        }
        func baseForeground(_ definition: CodeThemeDefinition) -> String {
            definition.color("editor.foreground") ?? (definition.isDark ? "#E6EDF3" : "#1F2328")
        }
        background = color("editor.background", lightFallback: "#F6F8FA", darkFallback: "#161B22")
        foreground = color("editor.foreground", lightFallback: "#1F2328", darkFallback: "#E6EDF3")
        border = color("editorWidget.border", lightFallback: "#D0D7DE", darkFallback: "#30363D")
        caret = Self.adaptive(light.color("editorCursor.foreground") ?? baseForeground(light),
                              second.color("editorCursor.foreground") ?? baseForeground(second))
        selection = color("editor.selectionBackground", lightFallback: "#B6E3FF", darkFallback: "#264F78")
        selectionForeground = Self.adaptive(light.color("editor.selectionForeground") ?? baseForeground(light),
                                             second.color("editor.selectionForeground") ?? baseForeground(second))
    }

    func token(_ token: CodeToken, language: CodeLanguage) -> TokenStyle {
        let key = token.rawValue + ":" + language.rawValue
        if let cached = tokens[key] { return cached }
        let first = resolve(token, language: language, theme: light)
        let second = resolve(token, language: language, theme: dark)
        let style = TokenStyle(foreground: Self.adaptive(first.foreground!, second.foreground!),
                               fontStyle: first.fontStyle ?? "")
        tokens[key] = style
        return style
    }

    func attributes(for token: CodeToken, language: CodeLanguage) -> [NSAttributedString.Key: Any] {
        let typography = NoteStyleSettings.shared.values.typography
        if tokenTypography != typography {
            tokenTypography = typography
            tokenAttributes.removeAll(keepingCapacity: true)
        }
        let key = token.rawValue + ":" + language.rawValue
        if let cached = tokenAttributes[key] { return cached }
        let style = self.token(token, language: language)
        let traits = style.fontStyle.split(separator: " ")
        var font = NoteStyleSettings.shared.codeFont(weight: traits.contains("bold") ? .bold : .regular)
        if traits.contains("italic") { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
        // Keep the adaptive NSColor, not a color resolved for today's appearance.
        let attributes: [NSAttributedString.Key: Any] = [
            .foregroundColor: style.foreground, .font: font,
            .underlineStyle: traits.contains("underline") ? NSUnderlineStyle.single.rawValue : 0,
            .strikethroughStyle: traits.contains("strikethrough") ? NSUnderlineStyle.single.rawValue : 0
        ]
        tokenAttributes[key] = attributes
        return attributes
    }

    private func resolve(_ token: CodeToken, language: CodeLanguage, theme: CodeThemeDefinition) -> ThemeTokenSettings {
        var result = ThemeTokenSettings(foreground: theme.color("editor.foreground") ?? (theme.isDark ? "#E6EDF3" : "#1F2328"))
        var colorScore = -1, fontScore = -1
        for rule in theme.rules {
            let scoped = rule.scope?.values.flatMap { $0.split(separator: ",").map(String.init) } ?? []
            let selectors = scoped.isEmpty ? [""] : scoped
            let score = selectors.flatMap { selector in
                token.scopes(language: language).map { Self.score(selector: selector, stack: $0) }
            }.max() ?? -1
            guard score >= 0 else { continue }
            if let color = rule.settings.foreground, ThemeRGBA(color) != nil, score >= colorScore {
                result.foreground = color
                colorScore = score
            }
            if let style = rule.settings.fontStyle, score >= fontScore {
                result.fontStyle = style
                fontScore = score
            }
        }
        return result
    }

    private static func score(selector: String, stack: [String]) -> Int {
        let atoms = selector.split(whereSeparator: \.isWhitespace).map(String.init)
        if atoms.isEmpty { return 0 }
        // Common TextMate dotted scopes and ancestor selectors. Complex scope
        // expressions and IDE semantic tokens are outside this scope adapter.
        guard atoms.allSatisfy({ $0.allSatisfy { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_" } && $0 != "-" }) else { return -1 }
        var remaining = stack.startIndex
        var score = 0
        for atom in atoms {
            guard let index = stack[remaining...].firstIndex(where: { $0 == atom || $0.hasPrefix(atom + ".") }) else { return -1 }
            score += atom.split(separator: ".").count * 10 + index
            remaining = index + 1
        }
        return score + (atoms.count - 1) * 100
    }

    private static func adaptive(_ first: String, _ second: String) -> NSColor {
        let light = ThemeRGBA(first)!, dark = ThemeRGBA(second)!
        if first == second { return NSColor(srgbRed: light.red, green: light.green, blue: light.blue, alpha: light.alpha) }
        return NSColor(name: nil) { appearance in
            let value = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: value.red, green: value.green, blue: value.blue, alpha: value.alpha)
        }
    }

    static let github = NativeCodeTheme(light: githubDefinition(dark: false), dark: githubDefinition(dark: true))

    private static func githubDefinition(dark: Bool) -> CodeThemeDefinition {
        let palette = dark
            ? ["#161B22", "#E6EDF3", "#8B949E", "#FF7B72", "#A5D6FF", "#79C0FF", "#D2A8FF"]
            : ["#F6F8FA", "#1F2328", "#656D76", "#CF222E", "#0A3069", "#0550AE", "#8250DF"]
        let scopes = ["comment", "keyword, storage", "string", "constant", "entity.name.function, support.function"]
        return CodeThemeDefinition(name: "GitHub", type: dark ? "dark" : "light",
                                   colors: ["editor.background": palette[0], "editor.foreground": palette[1]],
                                   rules: zip(scopes, palette.dropFirst(2)).map {
                                       ThemeTokenRule(scope: ThemeScope([$0.0]), settings: ThemeTokenSettings(foreground: $0.1))
                                   } + [
                                    ThemeTokenRule(scope: ThemeScope(["entity.name.tag"]),
                                                   settings: ThemeTokenSettings(foreground: dark ? "#7EE787" : "#116329")),
                                    ThemeTokenRule(scope: ThemeScope(["entity.other.attribute-name"]),
                                                   settings: ThemeTokenSettings(foreground: palette[6])),
                                    ThemeTokenRule(scope: ThemeScope(["entity.name.type", "support.class"]),
                                                   settings: ThemeTokenSettings(foreground: palette[5]))
                                   ])
    }
}
