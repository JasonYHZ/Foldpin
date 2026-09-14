import Foundation
import CoreGraphics

nonisolated struct NoteDocument: Codable, Equatable, Sendable {
    static let currentVersion = 2
    var version = currentVersion
    var id = UUID()
    var content = NoteContent()
    var text: String {
        get { content.plainText }
        set { content = NoteContent(plainText: newValue) }
    }
    var isPinned = false
    var isShelved = false
    var isCollapsed = false
    var color: NoteColor = .original
    var isFavorite = false
    var createdAt = Date()
    var icon: String?
    var deletedAt: Date?
    var frame: NoteFrame?
    var modifiedAt = Date()

    init() {}

    private enum CodingKeys: String, CodingKey {
        case version, id, text, content, isPinned, isShelved, isCollapsed, color, icon, isFavorite, createdAt, deletedAt, frame, modifiedAt
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let sourceVersion = try values.decode(Int.self, forKey: .version)
        guard (1...Self.currentVersion).contains(sourceVersion) else { throw NoteFileError.unsupportedVersion }
        version = Self.currentVersion
        id = try values.decode(UUID.self, forKey: .id)
        if sourceVersion == 1 {
            content = NoteContent(plainText: try values.decode(String.self, forKey: .text))
        } else {
            content = try values.decode(NoteContent.self, forKey: .content)
        }
        isPinned = try values.decode(Bool.self, forKey: .isPinned)
        isShelved = try values.decode(Bool.self, forKey: .isShelved)
        // Existing v1 notes predate the title-bar collapse option.
        isCollapsed = try values.decodeIfPresent(Bool.self, forKey: .isCollapsed) ?? false
        // Optional v2 metadata: older notes and unknown future presets use the
        // original surface without changing the note's content on load.
        color = NoteColor(rawValue: try values.decodeIfPresent(String.self, forKey: .color) ?? "") ?? .original
        icon = try values.decodeIfPresent(String.self, forKey: .icon).flatMap(NoteIcon.normalized)
        deletedAt = try values.decodeIfPresent(Date.self, forKey: .deletedAt)
        frame = try values.decodeIfPresent(NoteFrame.self, forKey: .frame)
        modifiedAt = try values.decode(Date.self, forKey: .modifiedAt)
        createdAt = try values.decodeIfPresent(Date.self, forKey: .createdAt) ?? modifiedAt
        isFavorite = try values.decodeIfPresent(Bool.self, forKey: .isFavorite) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(version, forKey: .version)
        try values.encode(id, forKey: .id)
        try values.encode(content, forKey: .content)
        try values.encode(isPinned, forKey: .isPinned)
        try values.encode(isShelved, forKey: .isShelved)
        try values.encode(isCollapsed, forKey: .isCollapsed)
        try values.encode(color, forKey: .color)
        try values.encodeIfPresent(icon, forKey: .icon)
        try values.encode(isFavorite, forKey: .isFavorite)
        try values.encode(createdAt, forKey: .createdAt)
        try values.encodeIfPresent(deletedAt, forKey: .deletedAt)
        try values.encodeIfPresent(frame, forKey: .frame)
        try values.encode(modifiedAt, forKey: .modifiedAt)
    }

    func summary(bundle: Bundle = .main) -> String {
        text.split(whereSeparator: \.isNewline).first.map(String.init) ?? String(localized: "No content yet", bundle: bundle)
    }

    func validate() throws {
        guard version == Self.currentVersion else { throw NoteFileError.unsupportedVersion }
        try content.validate()
        if let icon, NoteIcon.normalized(icon) != icon { throw NoteFileError.invalidContent }
        if let deletedAt, !deletedAt.timeIntervalSinceReferenceDate.isFinite { throw NoteFileError.invalidContent }
        if let frame, !frame.isValid { throw NoteFileError.invalidLayout }
    }
}

nonisolated struct NoteFrame: Codable, Equatable, Sendable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    init(_ rect: CGRect) {
        x = rect.origin.x; y = rect.origin.y
        width = rect.width; height = rect.height
    }

    var rect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
    var isValid: Bool {
        [x, y, width, height].allSatisfy(\.isFinite) && width > 0 && height > 0
    }

    /// Keep the entire window reachable after a display is removed or resized.
    func fitted(to screens: [CGRect], fallback: CGRect,
                minimumSize: CGSize = CGSize(width: 280, height: 220)) -> CGRect {
        let candidates = screens.isEmpty ? [fallback] : screens
        let target = candidates.max { area(rect.intersection($0)) < area(rect.intersection($1)) } ?? fallback
        let visible = candidates.contains { area(rect.intersection($0)) > 0 } ? target : fallback
        let w = min(max(width, minimumSize.width), visible.width)
        let h = min(max(height, minimumSize.height), visible.height)
        return CGRect(x: min(max(x, visible.minX), visible.maxX - w),
                      y: min(max(y, visible.minY), visible.maxY - h), width: w, height: h)
    }

    private func area(_ rect: CGRect) -> Double { rect.isNull ? 0 : rect.width * rect.height }
}

/// Stored geometry always describes the expanded sheet; a strip keeps its top edge.
enum NoteLayout {
    static let headerHeight: CGFloat = 52
    static let editorHorizontalInset: CGFloat = 32
    static let minimumWidth: CGFloat = 280
    static let minimumExpandedHeight: CGFloat = 220

    static func visibleFrame(expanded: CGRect, collapsed: Bool) -> CGRect {
        guard collapsed else { return expanded }
        return CGRect(x: expanded.minX, y: expanded.maxY - headerHeight,
                      width: expanded.width, height: headerHeight)
    }

    static func expandedFrame(window: CGRect, collapsed: Bool, rememberedHeight: CGFloat) -> CGRect {
        guard collapsed else { return window }
        let height = max(rememberedHeight, minimumExpandedHeight)
        return CGRect(x: window.minX, y: window.maxY - height, width: window.width, height: height)
    }
}
