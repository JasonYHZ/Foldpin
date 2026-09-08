import AppKit

/// A lightweight native attachment draws the grid. Only the active cell gets
/// an NSTextView, so inactive tables do not keep one editor per cell alive.
@MainActor
struct TableBlockLayout {
    static let font = NSFont.systemFont(ofSize: 14)
    static let padding: CGFloat = 7
    let table: NoteTable
    let width: CGFloat
    let rowHeights: [CGFloat]

    init(table: NoteTable, width: CGFloat) {
        self.table = table
        self.width = max(80, width)
        let cellWidth = max(12, self.width / CGFloat(max(1, table.columnCount)) - Self.padding * 2)
        rowHeights = table.rows.map { row in
            max(34, row.map { text in
                let measured = text.isEmpty || text.hasSuffix("\n") || text.hasSuffix("\u{2028}") ? text + " " : text
                return ceil(NSAttributedString(string: measured, attributes: [.font: Self.font])
                    .boundingRect(with: NSSize(width: cellWidth, height: .greatestFiniteMagnitude),
                                  options: [.usesLineFragmentOrigin, .usesFontLeading]).height) + Self.padding * 2
            }.max() ?? 34)
        }
    }

    var size: NSSize { NSSize(width: width, height: rowHeights.reduce(0, +)) }

    func rect(row: Int, column: Int) -> NSRect {
        let w = width / CGFloat(max(1, table.columnCount))
        return NSRect(x: CGFloat(column) * w, y: rowHeights.prefix(row).reduce(0, +), width: w, height: rowHeights[row])
    }

    func cell(at point: NSPoint) -> (row: Int, column: Int)? {
        guard NSRect(origin: .zero, size: size).contains(point) else { return nil }
        for row in table.rows.indices {
            for column in table.rows[row].indices where rect(row: row, column: column).contains(point) { return (row, column) }
        }
        return nil
    }

    func image(color: NSColor) -> NSImage {
        NSImage(size: size, flipped: true) { bounds in
            NSColor.textBackgroundColor.withAlphaComponent(0.18).setFill()
            bounds.fill()
            for row in table.rows.indices {
                for column in table.rows[row].indices {
                    let cell = rect(row: row, column: column)
                    NSColor.separatorColor.setStroke()
                    let border = NSBezierPath(rect: cell.insetBy(dx: 0.5, dy: 0.5))
                    border.lineWidth = 1
                    border.stroke()
                    (table.rows[row][column] as NSString).draw(
                        with: cell.insetBy(dx: Self.padding, dy: Self.padding),
                        options: [.usesLineFragmentOrigin, .usesFontLeading],
                        attributes: [.font: Self.font, .foregroundColor: color])
                }
            }
            return true
        }
    }
}

@MainActor
final class TableCellTextView: NSTextView {
    weak var hostUndoManager: UndoManager?
    override var undoManager: UndoManager? { hostUndoManager }
    @objc func undo(_ sender: Any?) { if !hasMarkedText() { onHistory?(false) } }
    @objc func redo(_ sender: Any?) { if !hasMarkedText() { onHistory?(true) } }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(undo(_:)) { return !hasMarkedText() && hostUndoManager?.canUndo == true }
        if item.action == #selector(redo(_:)) { return !hasMarkedText() && hostUndoManager?.canRedo == true }
        return super.validateUserInterfaceItem(item)
    }
    var onTextChange: ((String) -> Void)?
    var onNavigate: ((Int) -> Void)?
    var onExit: (() -> Void)?
    var onHistory: ((Bool) -> Void)?

    override func didChangeText() {
        super.didChangeText()
        // Composition is saved too; the host never resets this cell's marked
        // text while it updates the attachment snapshot and document history.
        onTextChange?(string)
    }

    override func insertTab(_ sender: Any?) {
        guard !hasMarkedText() else { super.insertTab(sender); return }
        onNavigate?(1)
    }

    override func insertBacktab(_ sender: Any?) {
        guard !hasMarkedText() else { super.insertBacktab(sender); return }
        onNavigate?(-1)
    }

    override func cancelOperation(_ sender: Any?) {
        if hasMarkedText() { super.cancelOperation(sender) } else { onExit?() }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if event.charactersIgnoringModifiers?.lowercased() == "z", flags == .command || flags == [.command, .shift] {
            guard !hasMarkedText() else { return false }
            onHistory?(flags.contains(.shift)); return true
        }
        if event.keyCode == 36 && flags == .command { onExit?(); return true }
        return super.performKeyEquivalent(with: event)
    }

    override func paste(_ sender: Any?) { pasteAsPlainText(sender) }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSColor.controlAccentColor.withAlphaComponent(0.65).setStroke()
        NSBezierPath(rect: bounds.insetBy(dx: 0.5, dy: 0.5)).stroke()
    }
}
