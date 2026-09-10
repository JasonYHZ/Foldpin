import AppKit

/// One regular liquid-glass surface per editor popover. Existing controls stay
/// in the glass content slot; appearance changes never rebuild their state.
@MainActor
final class EditorGlassSurface: NSView {
    let content: NSView
    private let glass = NSGlassEffectView()
    private let cornerRadius: CGFloat
    private var accessibilityObserver: NSObjectProtocol?
    private(set) var usesGlass = true
    var requiresSolidBackground: () -> Bool = {
        NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency || NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
    }
    init(content: NSView, cornerRadius: CGFloat) {
        self.content = content; self.cornerRadius = cornerRadius
        super.init(frame: content.frame)
        wantsLayer = true
        layer?.cornerRadius = cornerRadius; layer?.masksToBounds = true
        glass.style = .regular; glass.cornerRadius = cornerRadius
        glass.contentView = content
        addSubview(glass)
        setAccessibilityElement(false)
        refreshMaterial()
        accessibilityObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.refreshMaterial() } }
    }
    required init?(coder: NSCoder) { nil }
    override var isOpaque: Bool { false }
    override var isFlipped: Bool { content.isFlipped }
    override func layout() {
        super.layout()
        glass.frame = bounds
        content.frame = bounds
    }
    func refreshMaterial() {
        let enabled = !requiresSolidBackground()
        if enabled != usesGlass {
            let responder = window?.firstResponder
            if enabled {
                content.removeFromSuperview(); glass.contentView = content; glass.isHidden = false
            } else {
                glass.contentView = nil; glass.isHidden = true; addSubview(content)
            }
            usesGlass = enabled
            if let responder, window?.firstResponder !== responder { window?.makeFirstResponder(responder) }
        }
        needsDisplay = true; needsLayout = true
    }
    override func draw(_ dirtyRect: NSRect) {
        guard !usesGlass else { return }
        EditorMenuPalette.background.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: cornerRadius, yRadius: cornerRadius).fill()
    }
    isolated deinit {
        if let accessibilityObserver { NSWorkspace.shared.notificationCenter.removeObserver(accessibilityObserver) }
    }
}
