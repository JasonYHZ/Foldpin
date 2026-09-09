import AppKit
import CoreGraphics

enum NoteWindowStyle {
    static let cornerRadius: CGFloat = 28
    static let shadowPadding: CGFloat = 36

    static func resolvedCornerRadius(for size: CGSize) -> CGFloat {
        min(cornerRadius, max(0, min(size.width, size.height) / 2))
    }
}

/// Only the perimeter participates in resizing; the center passes through to
/// the existing titlebar buttons and editor. The panel owns the drag session.
final class NoteResizeHandleView: NSView {
    override var isOpaque: Bool { false }

    func edges(at point: NSPoint) -> NoteResizeEdges {
        guard let window, window.styleMask.contains(.resizable) else { return [] }
        return NoteResizeEdges.hit(at: point, in: bounds,
                                   allowsVertical: window.maxSize.height > window.minSize.height)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        edges(at: convert(point, from: superview)).isEmpty ? nil : self
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        super.resetCursorRects()
        guard let window, window.styleMask.contains(.resizable) else { return }
        let e = NoteResizeEdges.edgeWidth
        let c = NoteResizeEdges.cornerWidth
        let w = bounds.width, h = bounds.height
        func cursor(_ rect: NSRect, _ position: NSCursor.FrameResizePosition) {
            addCursorRect(rect, cursor: .frameResize(position: position, directions: .all))
        }
        guard window.maxSize.height > window.minSize.height else {
            cursor(NSRect(x: 0, y: 0, width: e, height: h), .left)
            cursor(NSRect(x: w - e, y: 0, width: e, height: h), .right)
            return
        }
        cursor(NSRect(x: 0, y: c, width: e, height: max(0, h - 2 * c)), .left)
        cursor(NSRect(x: w - e, y: c, width: e, height: max(0, h - 2 * c)), .right)
        cursor(NSRect(x: c, y: 0, width: max(0, w - 2 * c), height: e), .bottom)
        cursor(NSRect(x: c, y: h - e, width: max(0, w - 2 * c), height: e), .top)
        cursor(NSRect(x: 0, y: 0, width: c, height: c), .bottomLeft)
        cursor(NSRect(x: w - c, y: 0, width: c, height: c), .bottomRight)
        cursor(NSRect(x: 0, y: h - c, width: c, height: c), .topLeft)
        cursor(NSRect(x: w - c, y: h - c, width: c, height: c), .topRight)
    }
}

/// A non-interactive child follows the paper through WindowServer, without
/// enlarging its resize hit area or changing its persisted geometry.
@MainActor
final class NoteShadowWindow: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        hidesOnDeactivate = false
        isExcludedFromWindowsMenu = true
        isRestorable = false
        setAccessibilityElement(false)
        contentView = NoteShadowView()
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        // This is decoration, not a reachable document window. Near the menu
        // bar its padding must extend beyond visibleFrame; constraining it
        // independently displaces the shadow from the paper it belongs to.
        frameRect
    }

    func show(below paper: NSWindow) {
        collectionBehavior = paper.collectionBehavior
        level = paper.level
        updateFrame(for: paper)
        if parent !== paper { paper.addChildWindow(self, ordered: .below) }
        order(.below, relativeTo: paper.windowNumber)
    }

    func updateFrame(for paper: NSWindow) {
        let target = paper.frame.insetBy(dx: -NoteWindowStyle.shadowPadding,
                                        dy: -NoteWindowStyle.shadowPadding)
        if frame != target { setFrame(target, display: true) }
    }
}

/// Draw only outside the rounded paper. Keeping the center transparent avoids
/// a dark backing being sampled by Liquid Glass.
enum NoteShadowDrawing {
    static func draw(in context: CGContext, canvas: CGRect, paper: CGRect) {
        guard paper.width > 0, paper.height > 0 else { return }
        let radius = NoteWindowStyle.resolvedCornerRadius(for: paper.size)
        let shape = CGPath(roundedRect: paper, cornerWidth: radius,
                           cornerHeight: radius, transform: nil)
        context.saveGState()
        context.addRect(canvas)
        context.addPath(shape)
        context.clip(using: .evenOdd)
        for (blur, drop, opacity): (CGFloat, CGFloat, CGFloat) in [(18, 5, 0.20), (3, 1, 0.12)] {
            context.saveGState()
            context.setShadow(offset: CGSize(width: 0, height: -drop), blur: blur,
                              color: CGColor(gray: 0, alpha: opacity))
            context.setFillColor(CGColor(gray: 0, alpha: 1))
            context.addPath(shape)
            context.fillPath()
            context.restoreGState()
        }
        context.restoreGState()
    }
}

@MainActor
private final class NoteShadowView: NSView {
    override var isOpaque: Bool { false }

    init() {
        super.init(frame: .zero)
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.clear(bounds)
        NoteShadowDrawing.draw(in: context, canvas: bounds,
                               paper: bounds.insetBy(dx: NoteWindowStyle.shadowPadding,
                                                     dy: NoteWindowStyle.shadowPadding))
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsDisplay = true
    }
}

/// One subtle rounded stroke. It never intercepts text selection or buttons.
@MainActor
final class NoteEdgeView: NSView {
    var isPaper = false {
        didSet { if isPaper != oldValue { needsDisplay = true } }
    }
    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let highContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        let width: CGFloat = highContrast ? 1 : 0.75
        let inset = width / 2
        let rect = bounds.insetBy(dx: inset, dy: inset)
        guard rect.width > 0, rect.height > 0 else { return }
        let radius = max(0, NoteWindowStyle.resolvedCornerRadius(for: bounds.size) - inset)
        let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        let color = isPaper ? NotePalette.paperText : (dark ? NSColor.white : NSColor.black)
        color.withAlphaComponent(highContrast ? 0.7 : (isPaper ? 0.24 : (dark ? 0.28 : 0.18))).setStroke()
        path.lineWidth = width
        path.stroke()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsDisplay = true
    }
}
