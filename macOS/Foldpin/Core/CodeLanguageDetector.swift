import Foundation

/// Compatibility entry point for noninteractive clients. Live editors obtain
/// language detection separately from token spans, without blocking AppKit.
nonisolated enum CodeLanguageDetector {
    static let maximumSampleLength = CodeSyntaxEngine.maximumSampleLength

    static func detect(_ source: String) -> CodeLanguage {
        CodeSyntaxEngine.shared.detectLanguageSynchronously(source)
    }
}
