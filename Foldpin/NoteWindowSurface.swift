import AppKit
import SwiftUI
import Foundation

/// One native glass surface behind the existing editor and controls.
@MainActor
final class NoteWindowSurface: NSView {
    private let hosting: NSView
    private let glass = NSGlassEffectView()
    private let edge = NoteEdgeView()
    private var usesGlass: Bool?
    private var preferenceObserver: NSObjectProtocol?
    private var accessibilityObserver: NSObjectProtocol?

    init(content: NSView) {
        hosting = content
        super.init(frame: .zero)
        // Clip the entire native surface, not just SwiftUI's content. This
        // keeps composited content inside the same corners in either material.
        wantsLayer = true
        layer?.cornerRadius = NoteWindowStyle.cornerRadius
        layer?.masksToBounds = true
        glass.cornerRadius = NoteWindowStyle.cornerRadius
        glass.style = .regular
        addSubview(glass)
        edge.setAccessibilityElement(false)
        addSubview(edge)
        refreshAppearance()
        preferenceObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: UserDefaults.standard, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshAppearance() }
        }
        accessibilityObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshAppearance() }
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var isOpaque: Bool { false }

    override func layout() {
        super.layout()
        // Fill the borderless panel: an inset leaves a second outline around
        // the glass instead of a single rounded sheet.
        let surface = bounds
        guard surface.width > 0, surface.height > 0 else { return }
        if glass.frame != surface { glass.frame = surface }
        if usesGlass != true, hosting.frame != surface { hosting.frame = surface }
        if edge.frame != surface { edge.frame = surface }
    }

    private func refreshAppearance() {
        let choice = NoteAppearance(rawValue: UserDefaults.standard.string(forKey: NoteAppearance.preferenceKey) ?? "") ?? .paper
        let workspace = NSWorkspace.shared
        let enabled = choice == .translucent && !workspace.accessibilityDisplayShouldReduceTransparency
            && !workspace.accessibilityDisplayShouldIncreaseContrast
        edge.needsDisplay = true
        guard usesGlass != enabled else { return }
        let responder = window?.firstResponder as? NSView
        let restoreResponder = responder?.isDescendant(of: hosting) == true
        // Reparent the same hosting view; never rebuild NSTextView or its undo stack.
        if enabled {
            hosting.removeFromSuperview()
            glass.contentView = hosting
            glass.isHidden = false
        } else {
            glass.contentView = nil
            glass.isHidden = true
            addSubview(hosting, positioned: .below, relativeTo: edge)
        }
        usesGlass = enabled
        needsLayout = true
        if restoreResponder, let responder { window?.makeFirstResponder(responder) }
    }

    deinit {
        if let preferenceObserver { NotificationCenter.default.removeObserver(preferenceObserver) }
        if let accessibilityObserver { NSWorkspace.shared.notificationCenter.removeObserver(accessibilityObserver) }
    }
}

final class TransparentNoteHostingView<Content: View>: NSHostingView<Content> {
    override var isOpaque: Bool { false }
}
