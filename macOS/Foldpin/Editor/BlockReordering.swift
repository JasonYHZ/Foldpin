import AppKit

@MainActor
enum BlockReordering {
    static let pasteboardType = NSPasteboard.PasteboardType("dev.jasonyu.foldpin.local-block-move")

    /// A destination is a gap before an existing block, or nil for the end.
    /// Resolve IDs after removing the source to avoid downward-move off-by-one.
    static func moving(_ blockID: UUID, before targetID: UUID?, in content: NoteContent)
        -> (content: NoteContent, index: Int)? {
        guard let source = content.blocks.firstIndex(where: { $0.id == blockID }),
              let destination = destinationIndex(of: blockID, before: targetID, in: content) else { return nil }
        var next = content
        let block = next.blocks.remove(at: source)
        next.blocks.insert(block, at: destination)
        return (next, destination)
    }

    /// Pointer updates only validate the gap; copying the block array waits
    /// until the actual drop, even when the document contains large tables.
    static func destinationIndex(of blockID: UUID, before targetID: UUID?, in content: NoteContent) -> Int? {
        guard let source = content.blocks.firstIndex(where: { $0.id == blockID }), targetID != blockID else { return nil }
        let destination: Int
        if let targetID {
            guard let index = content.blocks.firstIndex(where: { $0.id == targetID }) else { return nil }
            destination = index > source ? index - 1 : index
        } else { destination = content.blocks.count - 1 }
        guard source != destination else { return nil }
        return destination
    }

    static func scrollStep(at point: NSPoint, in viewport: NSRect) -> CGFloat {
        guard viewport.contains(point) else { return 0 }
        let edge = min(36, viewport.height / 3)
        if point.y < viewport.minY + edge { return -min(14, max(2, (viewport.minY + edge - point.y) * 0.4)) }
        if point.y > viewport.maxY - edge { return min(14, max(2, (point.y - viewport.maxY + edge) * 0.4)) }
        return 0
    }
}

struct BlockDragPreview {
    let token: UUID
    let image: NSImage
}

struct BlockDropTarget {
    let beforeBlockID: UUID?
    let indicator: NSRect
}

struct BlockDragState {
    let token = UUID()
    let blockID: UUID
    let originalOrder: [UUID]
}
