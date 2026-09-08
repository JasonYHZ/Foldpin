import Foundation

/// Typing shortcuts for the block types Foldpin already stores. This does not
/// parse documents or reinterpret imported / previously saved text.
struct MarkdownBlockShortcut {
    enum Trigger { case space, newline }

    let kind: NoteBlockKind
    var isChecked = false
    var language: CodeLanguage = .plain

    static func match(prefix: String, trigger: Trigger) -> Self? {
        if prefix.hasPrefix("```") {
            let info = String(prefix.dropFirst(3)).lowercased()
            let aliases: [String: CodeLanguage] = [
                "": .plain, "text": .plain, "plain": .plain, "plaintext": .plain,
                "js": .javascript, "ts": .typescript, "py": .python,
                "sh": .shell, "bash": .shell, "zsh": .shell
            ]
            guard let language = aliases[info] ?? CodeLanguage(rawValue: info) else { return nil }
            return Self(kind: .code, language: language)
        }
        guard trigger == .space else { return nil }
        switch prefix {
        case "#": return Self(kind: .heading)
        case "##": return Self(kind: .subheading)
        case "-", "*", "+": return Self(kind: .bullet)
        case ">": return Self(kind: .quote)
        case "[]", "[ ]", "- []", "- [ ]", "* [ ]", "+ [ ]": return Self(kind: .task)
        case "[x]", "[X]", "- [x]", "- [X]", "* [x]", "+ [x]": return Self(kind: .task, isChecked: true)
        default: return nil
        }
    }
}
