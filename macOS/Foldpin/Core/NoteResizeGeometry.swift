import Foundation
import CoreGraphics

struct NoteResizeEdges: OptionSet {
    let rawValue: Int
    static let left = Self(rawValue: 1)
    static let right = Self(rawValue: 2)
    static let bottom = Self(rawValue: 4)
    static let top = Self(rawValue: 8)

    static let edgeWidth: CGFloat = 6
    static let cornerWidth: CGFloat = 14

    static func hit(at point: CGPoint, in bounds: CGRect, allowsVertical: Bool) -> Self {
        guard bounds.contains(point) else { return [] }
        let x = point.x - bounds.minX
        let y = point.y - bounds.minY
        let nearLeft = x < cornerWidth
        let nearRight = x >= bounds.width - cornerWidth
        let nearBottom = y < cornerWidth
        let nearTop = y >= bounds.height - cornerWidth
        if allowsVertical {
            if nearLeft && nearBottom { return [.left, .bottom] }
            if nearRight && nearBottom { return [.right, .bottom] }
            if nearLeft && nearTop { return [.left, .top] }
            if nearRight && nearTop { return [.right, .top] }
        }
        if x < edgeWidth { return .left }
        if x >= bounds.width - edgeWidth { return .right }
        if allowsVertical && y < edgeWidth { return .bottom }
        if allowsVertical && y >= bounds.height - edgeWidth { return .top }
        return []
    }

    func resizing(_ frame: CGRect, by delta: CGSize, minimum: CGSize, maximum: CGSize) -> CGRect {
        var result = frame
        if contains(.left) || contains(.right) {
            let width = frame.width + (contains(.left) ? -delta.width : delta.width)
            result.size.width = min(max(width, minimum.width), max(minimum.width, maximum.width))
            if contains(.left) { result.origin.x = frame.maxX - result.width }
        }
        if contains(.bottom) || contains(.top) {
            let height = frame.height + (contains(.bottom) ? -delta.height : delta.height)
            result.size.height = min(max(height, minimum.height), max(minimum.height, maximum.height))
            if contains(.bottom) { result.origin.y = frame.maxY - result.height }
        }
        return result
    }
}
