import AppKit

/// Shared semantic colors for the slash and paper action menus.
enum EditorMenuPalette {
    static var background: NSColor { .controlBackgroundColor }
    static var border: NSColor { .separatorColor }
    static var selection: NSColor { .quaternaryLabelColor.withAlphaComponent(0.08) }
}
