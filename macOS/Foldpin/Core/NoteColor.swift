import Foundation

/// Per-note presentation metadata. Material and light/dark remain app preferences.
enum NoteColor: String, Codable, CaseIterable, Sendable {
    case original, yellow, green, blue, pink, purple

    func title(bundle: Bundle = .main) -> String {
        switch self {
        case .original: String(localized: "Original", bundle: bundle)
        case .yellow: String(localized: "Yellow", bundle: bundle)
        case .green: String(localized: "Green", bundle: bundle)
        case .blue: String(localized: "Blue", bundle: bundle)
        case .pink: String(localized: "Pink", bundle: bundle)
        case .purple: String(localized: "Purple", bundle: bundle)
        }
    }
}
