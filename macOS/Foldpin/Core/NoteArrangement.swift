import Foundation
import CoreGraphics

/// Pure desktop geometry. Input order is library order so repeated arrangements
/// remain stable; neither packing nor fallback changes a window's size.
enum NoteArrangement {
    struct Item: Equatable {
        let id: UUID
        let frame: CGRect
    }
    struct Placement: Equatable {
        let id: UUID
        let before: CGRect
        let after: CGRect
    }

    static func screenIndex(for frame: CGRect, screens: [CGRect], fallback: Int = 0) -> Int? {
        guard !screens.isEmpty else { return nil }
        let fallback = min(max(0, fallback), screens.count - 1)
        var best = fallback
        var area: CGFloat = 0
        for (index, screen) in screens.enumerated() {
            let intersection = frame.intersection(screen)
            let overlap = intersection.isNull ? 0 : intersection.width * intersection.height
            if overlap > area { best = index; area = overlap }
        }
        return best
    }

    static func placements(for items: [Item], screens: [CGRect], fallback: Int = 0) -> [Placement] {
        var result: [Placement] = []
        for (index, screen) in screens.enumerated() where screen.width > 0 && screen.height > 0 {
            let inset = min(16, min(screen.width, screen.height) / 4)
            let area = screen.insetBy(dx: inset, dy: inset)
            let group = items.filter { NoteFrame($0.frame).isValid && screenIndex(for: $0.frame, screens: screens, fallback: fallback) == index }
            var x = area.minX
            var top = area.maxY
            var rowHeight: CGFloat = 0
            var overflow = 0
            var isOverflowing = false
            for item in group {
                let size = item.frame.size
                if x > area.minX && x + size.width > area.maxX {
                    x = area.minX
                    top -= rowHeight + 12
                    rowHeight = 0
                }
                if top - size.height < area.minY { isOverflowing = true }
                let frame: CGRect
                if isOverflowing {
                    // Once full, use a bounded cascade instead of shrinking notes.
                    let span = max(0, min(area.width - size.width, area.height - size.height))
                    let steps = max(1, Int(span / 24) + 1)
                    let offset = CGFloat((overflow + 1) % steps) * 24
                    frame = CGRect(x: area.minX + offset, y: area.maxY - offset - size.height,
                                   width: size.width, height: size.height)
                    overflow += 1
                } else {
                    frame = CGRect(x: x, y: top - size.height, width: size.width, height: size.height)
                    x += size.width + 12
                    rowHeight = max(rowHeight, size.height)
                }
                result.append(Placement(id: item.id, before: item.frame, after: frame))
            }
        }
        return result
    }

    /// Undo never reopens a note or overwrites a subsequent manual move/resize.
    static func undoFrame(for placement: Placement, current: CGRect, screens: [CGRect], fallback: Int = 0) -> CGRect? {
        guard current == placement.after,
              let index = screenIndex(for: placement.before, screens: screens, fallback: fallback) else { return nil }
        let screen = screens[index]
        let before = placement.before
        return CGRect(x: min(max(before.minX, screen.minX), max(screen.minX, screen.maxX - before.width)),
                      y: max(min(before.minY, screen.maxY - before.height), min(screen.minY, screen.maxY - before.height)),
                      width: before.width, height: before.height)
    }
}
