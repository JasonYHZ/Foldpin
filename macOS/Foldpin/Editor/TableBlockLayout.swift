import AppKit

/// A lightweight native attachment draws the grid. Only the active cell gets
/// an NSTextView, so inactive tables do not keep one editor per cell alive.
@MainActor
struct TableBlockLayout {
    static var font: NSFont { NoteStyleSettings.shared.bodyFont(size: NoteStyleSettings.shared.values.typography.bodySize * 14 / 15) }
    static var headerFont: NSFont { NoteStyleSettings.shared.bodyFont(size: NoteStyleSettings.shared.values.typography.bodySize * 14 / 15, weight: .semibold) }
    static let controlsHeight: CGFloat = 24
    static let padding: CGFloat = 7
    let typography = NoteStyleSettings.shared.values.typography
    let table: NoteTable
    let width: CGFloat
    let rowHeights: [CGFloat]
    let rowOffsets: [CGFloat]

    init(table: NoteTable, width: CGFloat, reusing previous: TableBlockLayout? = nil) {
        self.table = table
        let layoutWidth = max(80, width)
        self.width = layoutWidth
        let cellWidth = max(12, layoutWidth / CGFloat(max(1, table.columnCount)) - Self.padding * 2)
        let currentTypography = NoteStyleSettings.shared.values.typography
        let reusable = previous.flatMap { $0.typography == currentTypography && $0.width == layoutWidth && $0.table.columnCount == table.columnCount ? $0 : nil }
        rowHeights = table.rows.enumerated().map { index, row in
            if let reusable, reusable.table.rows.indices.contains(index), reusable.table.rows[index] == row,
               reusable.table.headerColumn == table.headerColumn, (index != 0 || reusable.table.headerRow == table.headerRow) {
                return reusable.rowHeights[index]
            }
            return max(34, row.enumerated().map { column, text in
                let measured = text.isEmpty || text.hasSuffix("\n") || text.hasSuffix("\u{2028}") ? text + " " : text
                return ceil(NSAttributedString(string: measured, attributes: [.font: table.isHeader(row: index, column: column) ? Self.headerFont : Self.font])
                    .boundingRect(with: NSSize(width: cellWidth, height: .greatestFiniteMagnitude),
                                  options: [.usesLineFragmentOrigin, .usesFontLeading]).height) + Self.padding * 2
            }.max() ?? 34)
        }
        var offsets: [CGFloat] = [0]
        for height in rowHeights { offsets.append(offsets.last! + height) }
        rowOffsets = offsets
    }

    var size: NSSize { NSSize(width: width, height: rowOffsets.last ?? 0) }
    var attachmentSize: NSSize { NSSize(width: width, height: size.height + Self.controlsHeight) }

    func rect(row: Int, column: Int) -> NSRect {
        let w = width / CGFloat(max(1, table.columnCount))
        return NSRect(x: CGFloat(column) * w, y: rowOffsets[row], width: w, height: rowHeights[row])
    }

    func cell(at point: NSPoint) -> (row: Int, column: Int)? {
        guard NSRect(origin: .zero, size: size).contains(point) else { return nil }
        guard let row = table.rows.indices.first(where: { point.y < rowOffsets[$0 + 1] }) else { return nil }
        return (row, min(table.columnCount - 1, Int(point.x / (width / CGFloat(table.columnCount)))))
    }

    func image(color: NSColor) -> NSImage {
        NSImage(size: attachmentSize, flipped: true) { bounds in
            (color == NotePalette.paperText ? NSColor.white.withAlphaComponent(0.06)
                : NSColor.textBackgroundColor.withAlphaComponent(0.18)).setFill()
            NSRect(origin: .zero, size: size).fill()
            for row in table.rows.indices {
                for column in table.rows[row].indices {
                    let cell = rect(row: row, column: column)
                    let header = table.isHeader(row: row, column: column)
                    if header { color.withAlphaComponent(0.06).setFill(); cell.fill() }
                    NotePalette.rule(for: color).setStroke()
                    let border = NSBezierPath(rect: cell.insetBy(dx: 0.5, dy: 0.5))
                    border.lineWidth = 1
                    border.stroke()
                    (table.rows[row][column] as NSString).draw(
                        with: cell.insetBy(dx: Self.padding, dy: Self.padding),
                        options: [.usesLineFragmentOrigin, .usesFontLeading],
                        attributes: [.font: header ? Self.headerFont : Self.font, .foregroundColor: color])
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
    var onContextMenu: (() -> NSMenu?)?

    override func menu(for event: NSEvent) -> NSMenu? {
        guard !hasMarkedText() else { return nil }
        return onContextMenu?() ?? super.menu(for: event)
    }

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
