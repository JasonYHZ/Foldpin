import AppKit

/// Template images let NSMenu supply the correct tint for selection and appearance.
@MainActor
enum BlockMenuIcon {
    static func image(for kind: NoteBlockKind) -> NSImage? { images[kind] }

    private static let images: [NoteBlockKind: NSImage] = {
        var result: [NoteBlockKind: NSImage] = [:]
        for kind in NoteBlockKind.allCases {
            let image: NSImage?
            if kind == .paragraph || kind.headingLevel != nil {
                let letter = kind == .paragraph ? "T" : "H"
                let level = kind.headingLevel.map { String($0) } ?? ""
                image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
                    let label = NSMutableAttributedString(string: letter, attributes: [
                        .font: NSFont.systemFont(ofSize: 14, weight: letter == "T" ? .medium : .regular),
                        .foregroundColor: NSColor.black
                    ])
                    if !level.isEmpty {
                        label.append(NSAttributedString(string: level, attributes: [
                            .font: NSFont.systemFont(ofSize: 9), .foregroundColor: NSColor.black, .baselineOffset: -1.5
                        ]))
                    }
                    let size = label.size()
                    label.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2))
                    return true
                }
            } else {
                image = SlashCommandMenu.Entry(kind: kind, title: "").symbol
                    .flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }?
                    .withSymbolConfiguration(.init(pointSize: 14, weight: kind == .divider ? .ultraLight : .regular))
            }
            image?.isTemplate = true
            result[kind] = image
        }
        return result
    }()
}
