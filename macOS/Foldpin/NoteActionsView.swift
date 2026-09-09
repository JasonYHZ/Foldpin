import AppKit
import SwiftUI

struct ShortcutKeycaps: View {
    let keys: [String]
    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(keys.enumerated()), id: \.offset) { _, key in
                Text(key).font(.system(size: 10, weight: .medium, design: .rounded))
                    .frame(minWidth: 16, minHeight: 18)
                    .background(.primary.opacity(0.035), in: .rect(cornerRadius: 4))
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.primary.opacity(0.18), lineWidth: 0.7))
            }
        }
        .accessibilityHidden(true)
    }
}

/// The native field editor owns typing/IME. Navigation is intercepted only
/// when composition is complete; hover never changes keyboard selection.
private struct ActionSearchField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var navigate: (Int) -> Void
    var execute: () -> Void
    var openSubmenu: () -> Bool
    var dismiss: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.delegate = context.coordinator
        field.placeholderString = placeholder
        field.font = .systemFont(ofSize: 13)
        field.focusRingType = .none
        field.sendsSearchStringImmediately = true
        field.setAccessibilityLabel(placeholder)
        DispatchQueue.main.async { [weak field] in
            guard let field, let window = field.window, window.isVisible else { return }
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(field)
        }
        return field
    }
    func updateNSView(_ field: NSSearchField, context: Context) {
        context.coordinator.parent = self
        field.placeholderString = placeholder
        field.setAccessibilityLabel(placeholder)
        if field.stringValue != text { field.stringValue = text }
    }
    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var parent: ActionSearchField
        init(_ parent: ActionSearchField) { self.parent = parent }
        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            parent.text = field.stringValue
        }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard !textView.hasMarkedText() else { return false }
            switch selector {
            case #selector(NSResponder.moveDown(_:)): parent.navigate(1)
            case #selector(NSResponder.moveUp(_:)): parent.navigate(-1)
            case #selector(NSResponder.insertNewline(_:)): parent.execute()
            case #selector(NSResponder.moveRight(_:)):
                guard parent.text.isEmpty || (textView.selectedRange().length == 0 &&
                    textView.selectedRange().location == (parent.text as NSString).length) else { return false }
                return parent.openSubmenu()
            case #selector(NSResponder.cancelOperation(_:)): parent.dismiss()
            default: return false
            }
            return true
        }
    }
}

struct NoteActionsView: View {
    @ObservedObject private var language = LanguageSettings.shared
    @ObservedObject var store: NoteStore
    let width: CGFloat
    let height: CGFloat
    let isEnabled: (NoteAction) -> Bool
    let perform: (NoteAction) -> Void
    let dismiss: () -> Void
    let openColors: (NSView) -> Void
    @State private var query = ""
    @State private var selected: NoteAction?
    @State private var colorAnchor = ActionMenuAnchorReference()

    private let sections: [[NoteAction]] = [
        [.pin, .collapse, .shelve, .copyAll, .duplicateNote, .icon, .color],
        [.newNote, .shelf, .arrange, .undoArrangement, .shelveAll],
        [.settings, .captureShortcut],
        [.deleteNote]
    ]
    private func title(_ action: NoteAction) -> String {
        action.title(bundle: language.bundle, pinned: store.document.isPinned,
                     collapsed: store.isCollapsed, hasIcon: store.document.icon != nil)
    }
    private func matches(_ action: NoteAction) -> Bool {
        let terms = query.split(whereSeparator: \.isWhitespace)
        let haystack = title(action) + " " + action.rawValue + " " + action.keycaps.joined()
        return terms.allSatisfy { haystack.localizedStandardContains(String($0)) }
    }
    private var displayedSections: [[NoteAction]] {
        if !query.isEmpty { return sections + [NoteAction.colors] }
        return sections
    }
    private var filtered: [NoteAction] { displayedSections.flatMap { $0 }.filter(matches) }
    private var selectable: [NoteAction] { filtered.filter(isEnabled) }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(String(localized: "Actions", bundle: language.bundle)).font(.system(size: 12, weight: .medium))
                Spacer()
                Button(action: dismiss) { ShortcutKeycaps(keys: ["esc"]) }
                    .buttonStyle(.plain).help(String(localized: "Close menu", bundle: language.bundle))
                    .accessibilityLabel(String(localized: "Close menu", bundle: language.bundle))
            }
            .foregroundStyle(.secondary).padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 6)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(displayedSections.indices, id: \.self) { section in
                            let actions = displayedSections[section].filter(matches)
                            if !actions.isEmpty {
                                Text(sectionTitle(section)).font(.system(size: 10, weight: .medium))
                                    .foregroundStyle(.secondary).padding(.horizontal, 10).padding(.top, 8).padding(.bottom, 3)
                                ForEach(actions) { action in row(action).id(action) }
                            }
                        }
                        if filtered.isEmpty {
                            Text(String(localized: "No matching actions", bundle: language.bundle))
                                .foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.vertical, 28)
                        }
                    }.padding(.horizontal, 7).padding(.bottom, 8)
                }
                .frame(maxHeight: .infinity)
                .onChange(of: selected) { _, action in
                    if let action { proxy.scrollTo(action) }
                }
                .onChange(of: query) { _, _ in
                    if let action = selectable.first { proxy.scrollTo(action) }
                }
            }
            Divider()
            HStack(spacing: 10) {
                ActionSearchField(text: $query, placeholder: String(localized: "Search for actions…", bundle: language.bundle),
                                  navigate: move, execute: execute, openSubmenu: openSelectedSubmenu, dismiss: dismiss)
                ShortcutKeycaps(keys: ["↩"])
                    .foregroundStyle(.secondary)
            }.padding(12)
        }
        .frame(width: width, height: height)
        .background(Color(nsColor: EditorMenuPalette.background), in: .rect(cornerRadius: 15))
        .overlay(RoundedRectangle(cornerRadius: 15).strokeBorder(Color(nsColor: EditorMenuPalette.border), lineWidth: 0.75))
        .clipShape(.rect(cornerRadius: 15))
        .onAppear { selected = selectable.first }
        .onChange(of: query) { _, _ in selected = selectable.first }
        .onChange(of: selectable) { _, values in
            if selected.map({ !values.contains($0) }) ?? true { selected = values.first }
        }
    }
    private func sectionTitle(_ section: Int) -> String {
        if section == 4 { return String(localized: "Note Color", bundle: language.bundle) }
        return switch section {
        case 0: String(localized: "Current Note", bundle: language.bundle)
        case 1: String(localized: "Notes", bundle: language.bundle)
        case 2: String(localized: "Application", bundle: language.bundle)
        default: String(localized: "Current Note", bundle: language.bundle)
        }
    }
    private func row(_ action: NoteAction) -> some View {
        Button { activate(action) } label: {
            HStack(spacing: 10) {
                if let color = action.noteColor {
                    Image(nsImage: NotePalette.colorSwatch(for: color)).frame(width: 20)
                } else {
                    Image(systemName: action == .collapse && store.isCollapsed ? "chevron.down" :
                            action == .pin && store.document.isPinned ? "pin.fill" : action.symbol)
                        .font(.system(size: 15)).frame(width: 20)
                }
                Text(title(action)).font(.system(size: 13)).lineLimit(1)
                Spacer(minLength: 4)
                if action.noteColor == store.document.color { Image(systemName: "checkmark").font(.system(size: 10)) }
                ShortcutKeycaps(keys: action.keycaps).foregroundStyle(.secondary)
                if action == .color { Image(systemName: "chevron.right").font(.system(size: 10)).foregroundStyle(.secondary) }
            }
            .padding(.horizontal, 10).frame(height: 37)
            .contentShape(.rect)
            .background(Color(nsColor: EditorMenuPalette.selection).opacity(selected == action ? 1 : 0), in: .rect(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.accentColor, lineWidth: selected == action ? 2 : 0))
        }
        .buttonStyle(.plain).foregroundStyle(action == .deleteNote ? Color.red : Color.primary).disabled(!isEnabled(action))
        .accessibilityLabel(title(action) + " " + action.keycaps.joined())
        .accessibilityAddTraits(selected == action ? .isSelected : [])
        .background {
            if action == .color { ActionMenuAnchor(reference: colorAnchor) }
        }
    }
    private func move(_ delta: Int) {
        let values = selectable
        guard !values.isEmpty else { selected = nil; return }
        let index = selected.flatMap { values.firstIndex(of: $0) } ?? (delta > 0 ? -1 : values.count)
        selected = values[min(max(index + delta, 0), values.count - 1)]
    }
    private func activate(_ action: NoteAction) {
        if action == .color {
            selected = action
            _ = openSelectedSubmenu()
        }
        else { perform(action) }
    }
    private func openSelectedSubmenu() -> Bool {
        guard selected == .color, isEnabled(.color), let view = colorAnchor.view else { return false }
        openColors(view)
        return true
    }
    private func execute() {
        if let selected, isEnabled(selected) { activate(selected) }
    }
}

private final class ActionMenuAnchorReference { weak var view: NSView? }
private struct ActionMenuAnchor: NSViewRepresentable {
    let reference: ActionMenuAnchorReference
    func makeNSView(context: Context) -> NSView {
        let view = AnchorView(); reference.view = view; return view
    }
    func updateNSView(_ view: NSView, context: Context) { reference.view = view }
    private final class AnchorView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

/// A native child panel gives an exact bottom-right anchor without a popover
/// arrow or AppKit choosing a different side of the trigger.
@MainActor
final class NoteActionsPanel: NSObject {
    private var panel: ActionsPanel?
    private var eventMonitor: Any?
    private var deactivationObserver: NSObjectProtocol?
    private var colorPanel: SlashSuggestionPanel?
    private var colorList: ActionColorsView?
    private var colorAction: ((NoteAction) -> Void)?
    private weak var paper: NSWindow?
    private weak var previousResponder: NSResponder?
    var onClose: (() -> Void)?
    var isShown: Bool { panel?.isVisible == true }

    func show(in paper: NSWindow, anchorView: NSView?, store: NoteStore,
              isEnabled: @escaping (NoteAction) -> Bool, perform: @escaping (NoteAction) -> Void) {
        close()
        self.paper = paper
        previousResponder = paper.firstResponder
        paper.contentView?.layoutSubtreeIfNeeded()
        let anchor: NSPoint
        if !store.isCollapsed, let view = anchorView, view.window === paper {
            let point = NSPoint(x: view.bounds.maxX, y: view.isFlipped ? view.bounds.maxY : view.bounds.minY)
            anchor = paper.convertPoint(toScreen: view.convert(point, to: nil))
        } else { anchor = NSPoint(x: paper.frame.maxX - 12, y: paper.frame.minY + 8) }
        let screen = paper.screen?.visibleFrame ?? NSScreen.main!.visibleFrame
        let height = store.isCollapsed ? 380 : min(380, max(200, paper.frame.height - 16))
        let frame = NoteActionsLayout.frame(anchor: anchor, width: min(340, paper.frame.width - 24), height: height, screen: screen)
        let panel = ActionsPanel(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = true
        panel.level = paper.level
        panel.title = String(localized: "Actions", bundle: LanguageSettings.shared.bundle)
        let hosting = NSHostingView(rootView: NoteActionsView(
            store: store, width: frame.width, height: frame.height, isEnabled: isEnabled,
            perform: { [weak self] action in
                self?.close(restoringFocus: true)
                DispatchQueue.main.async { perform(action) }
            }, dismiss: { [weak self] in self?.close(restoringFocus: true) },
            openColors: { [weak self] view in
                self?.showColors(at: view, store: store, isEnabled: isEnabled, perform: perform)
            }))
        hosting.sizingOptions = []
        panel.contentView = hosting
        self.panel = panel
        panel.onResign = { [weak self] in self?.close() }
        paper.addChildWindow(panel, ordered: .above)
        panel.makeKeyAndOrderFront(nil)
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown, .scrollWheel]) { [weak self, weak panel] event in
            guard let self, let panel, self.isShown else { return event }
            if event.type == .scrollWheel {
                if event.window === panel { self.closeColors() }
                return event
            }
            if event.type != .keyDown {
                if let child = self.colorPanel, event.window === child { return event }
                self.closeColors()
                if event.window !== panel { self.close() }
                return event
            }
            guard event.window === panel else { return event }
            if let list = self.colorList,
               event.modifierFlags.intersection([.command, .shift, .option, .control]).isEmpty {
                switch event.keyCode {
                case 125: list.move(1)
                case 126: list.move(-1)
                case 123, 53: self.closeColors()
                case 124: break
                case 36, 76: self.colorAction?(list.selected)
                default: self.closeColors(); return event
                }
                return nil
            }
            guard let action = NoteAction.matching(key: event.charactersIgnoringModifiers, modifiers: event.modifierFlags) else {
                self.closeColors()
                return event
            }
            if !event.isARepeat {
                if action == .actions { self.close(restoringFocus: true) }
                else if isEnabled(action) {
                    self.close(restoringFocus: true)
                    DispatchQueue.main.async { perform(action) }
                }
            }
            return nil
        }
        deactivationObserver = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }
    }
    func close(restoringFocus: Bool = false) {
        closeColors()
        guard let panel else { return }
        self.panel = nil
        panel.onResign = nil
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor); self.eventMonitor = nil }
        if let deactivationObserver { NotificationCenter.default.removeObserver(deactivationObserver); self.deactivationObserver = nil }
        paper?.removeChildWindow(panel)
        panel.orderOut(nil)
        panel.close()
        onClose?()
        if restoringFocus, let paper, paper.isVisible, NSApp.isActive {
            paper.makeKeyAndOrderFront(nil)
            if let previousResponder { paper.makeFirstResponder(previousResponder) }
        }
    }

    private func showColors(at view: NSView, store: NoteStore,
                            isEnabled: @escaping (NoteAction) -> Bool, perform: @escaping (NoteAction) -> Void) {
        guard colorPanel == nil, let panel, view.window === panel else { return }
        let row = panel.convertToScreen(view.convert(view.bounds, to: nil))
        let screen = panel.screen?.visibleFrame ?? NSScreen.main!.visibleFrame
        let frame = NoteActionsLayout.submenuFrame(parent: panel.frame, row: row, screen: screen)
        let child = SlashSuggestionPanel(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        child.isReleasedWhenClosed = false
        child.isOpaque = false; child.backgroundColor = .clear; child.hasShadow = true
        child.hidesOnDeactivate = true; child.level = panel.level
        child.title = String(localized: "Note Color", bundle: LanguageSettings.shared.bundle)
        let list = ActionColorsView(frame: NSRect(origin: .zero, size: frame.size), color: store.document.color,
                                    bundle: LanguageSettings.shared.bundle, isEnabled: isEnabled)
        child.contentView = list
        colorPanel = child; colorList = list
        colorAction = { [weak self] action in
            guard isEnabled(action) else { return }
            self?.close(restoringFocus: true)
            DispatchQueue.main.async { perform(action) }
        }
        list.onChoose = { [weak self] in self?.colorAction?($0) }
        panel.addChildWindow(child, ordered: .above)
        child.orderFront(nil)
    }

    private func closeColors() {
        guard let child = colorPanel else { return }
        colorPanel = nil; colorList = nil; colorAction = nil
        child.parent?.removeChildWindow(child)
        child.orderOut(nil); child.close()
    }
}

/// The same AppKit row rendering as `/`; the parent keeps its field editor
/// while the child handles only selection and explicitly chosen actions.
private final class ActionColorsView: NSView {
    var onChoose: ((NoteAction) -> Void)?
    private var rows: [SlashSuggestionButton] = []
    private var selectedIndex = 0
    var selected: NoteAction { NoteAction.colors[selectedIndex] }
    override var isFlipped: Bool { true }

    init(frame: NSRect, color: NoteColor, bundle: Bundle, isEnabled: (NoteAction) -> Bool) {
        super.init(frame: frame)
        wantsLayer = true; layer?.cornerRadius = 12; layer?.masksToBounds = true
        let scroll = NSScrollView(frame: bounds.insetBy(dx: 4, dy: 6))
        scroll.drawsBackground = false; scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true; scroll.scrollerStyle = .overlay
        let list = FlippedList(frame: NSRect(x: 0, y: 0, width: scroll.bounds.width, height: CGFloat(NoteAction.colors.count) * 36))
        for (index, action) in NoteAction.colors.enumerated() {
            let row = SlashSuggestionButton(frame: NSRect(x: 0, y: CGFloat(index) * 36, width: list.bounds.width, height: 36))
            row.title = action.title(bundle: bundle)
            row.image = NotePalette.colorSwatch(for: action.noteColor!)
            row.shortcutHint = (action.noteColor == color ? "✓  " : "") + action.keycaps.joined()
            row.setAccessibilityLabel(row.title + " " + row.shortcutHint)
            row.isEnabled = isEnabled(action)
            row.tag = index; row.target = self; row.action = #selector(choose(_:))
            row.onHover = { [weak self] in self?.select(index) }
            list.addSubview(row); rows.append(row)
        }
        scroll.documentView = list; addSubview(scroll)
        select(NoteAction.colors.firstIndex(where: { $0.noteColor == color }) ?? 0)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func move(_ delta: Int) { select(min(max(selectedIndex + delta, 0), rows.count - 1)) }
    private func select(_ index: Int) {
        selectedIndex = index
        for (i, row) in rows.enumerated() {
            row.showsSelection = i == index; row.showsKeyboardFocus = i == index
        }
        rows[index].scrollToVisible(rows[index].bounds)
    }
    @objc private func choose(_ sender: NSButton) { onChoose?(NoteAction.colors[sender.tag]) }
    override func draw(_ dirtyRect: NSRect) {
        let outline = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 12, yRadius: 12)
        EditorMenuPalette.background.setFill(); outline.fill()
        EditorMenuPalette.border.setStroke(); outline.lineWidth = 0.75; outline.stroke()
    }
    private final class FlippedList: NSView { override var isFlipped: Bool { true } }
}

private final class ActionsPanel: NSPanel {
    var onResign: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func resignKey() { super.resignKey(); onResign?() }
}
