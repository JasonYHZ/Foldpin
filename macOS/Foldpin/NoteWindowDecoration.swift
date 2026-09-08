import AppKit
import CoreGraphics

enum NoteWindowStyle {
    static let cornerRadius: CGFloat = 16
    static let shadowPadding: CGFloat = 36
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
        let shape = CGPath(roundedRect: paper, cornerWidth: NoteWindowStyle.cornerRadius,
                           cornerHeight: NoteWindowStyle.cornerRadius, transform: nil)
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
    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let highContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        let width: CGFloat = highContrast ? 1 : 0.75
        let inset = width / 2
        let rect = bounds.insetBy(dx: inset, dy: inset)
        guard rect.width > 0, rect.height > 0 else { return }
        let path = NSBezierPath(roundedRect: rect,
                                xRadius: NoteWindowStyle.cornerRadius - inset,
                                yRadius: NoteWindowStyle.cornerRadius - inset)
        let color = dark ? NSColor.white : NSColor.black
        color.withAlphaComponent(highContrast ? 0.55 : (dark ? 0.28 : 0.18)).setStroke()
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
