import Foundation
import CoreGraphics

/// Screen coordinates: the action button's bottom-right is the menu anchor.
nonisolated enum NoteActionsLayout {
    static func submenuFrame(parent: CGRect, row: CGRect, screen: CGRect) -> CGRect {
        let safe = screen.insetBy(dx: 8, dy: 8)
        let width = min(220, safe.width)
        let height = min(228, safe.height)
        let right = parent.maxX + 4
        let x = right + width <= safe.maxX ? right : parent.minX - width - 4
        return CGRect(x: min(max(x, safe.minX), safe.maxX - width),
                      y: min(max(row.maxY - height + 6, safe.minY), safe.maxY - height),
                      width: width, height: height)
    }

    static func frame(anchor: CGPoint, width: CGFloat, height: CGFloat, screen: CGRect) -> CGRect {
        let safe = screen.insetBy(dx: 8, dy: 8)
        let size = CGSize(width: min(width, safe.width), height: min(height, safe.height))
        return CGRect(x: min(max(anchor.x - size.width, safe.minX), safe.maxX - size.width),
                      y: min(max(anchor.y, safe.minY), safe.maxY - size.height),
                      width: size.width, height: size.height)
    }
}
