import SwiftUI
import Combine

struct ContentView: View {
    @ObservedObject private var languageSettings = LanguageSettings.shared
    @ObservedObject var store: NoteStore
    @AppStorage(NoteAppearance.preferenceKey) private var appearance: NoteAppearance = .paper
    var titlebarState = NoteTitlebarState()
    var onPin: () -> Void
    var onCollapse: () -> Void
    var onClose: () -> Void
    var onShelve: () -> Void
    var onRetryLoad: () -> Void
    var onRevealError: () -> Void
    var onColorMenu: (() -> NSMenu?)? = nil
    var onActions: () -> Void = {}

    var body: some View {
        GeometryReader { geometry in
            let expandedHeight = store.isCollapsed ? (store.document.frame?.height ?? 340) : geometry.size.height
            let bodyHeight = max(expandedHeight - NoteLayout.headerHeight,
                                 NoteLayout.minimumExpandedHeight - NoteLayout.headerHeight)
            VStack(spacing: 0) {
                NoteTitlebar(store: store, state: titlebarState, ink: Color(nsColor: appearance.textColor), onPin: onPin, onCollapse: onCollapse, onClose: onClose, onShelve: onShelve, onColorMenu: onColorMenu)
                // Keep the same NSTextView at a usable height; only its visible
                // container collapses, preserving selection and the undo stack.
                noteBody
                    .frame(height: bodyHeight)
                    .frame(height: store.isCollapsed ? 0 : bodyHeight, alignment: .top)
                    .clipped()
                    .opacity(store.isCollapsed ? 0 : 1)
                    .allowsHitTesting(!store.isCollapsed)
                    .accessibilityHidden(store.isCollapsed)
            }
        }
        .background { NoteSheetFill(appearance: appearance, color: store.document.color).allowsHitTesting(false) }
        .clipShape(.rect(cornerRadius: NoteWindowStyle.cornerRadius))
        .ignoresSafeArea(.container, edges: .top)
        .environment(\.locale, languageSettings.locale)
        .onChange(of: store.saveError) { _, error in if error != nil { onRevealError() } }
        .onChange(of: store.loadError) { _, error in if error != nil { onRevealError() } }
    }

    private var noteBody: some View {
        VStack(spacing: 0) {
            if let message = store.loadError ?? store.saveError {
                VStack(alignment: .leading, spacing: 7) {
                    Text(message).font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
                    Button(store.loadError == nil ? String(localized: "Retry Save", bundle: languageSettings.bundle) : String(localized: "Retry Load", bundle: languageSettings.bundle)) {
                        if store.loadError == nil { store.flush() } else { onRetryLoad() }
                    }.font(.system(size: 11, weight: .medium))
                }
                .foregroundStyle(Color(nsColor: appearance.textColor))
                .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.red.opacity(0.12))
            }
            // The native block editor owns all empty-block hints.
            NoteEditor(store: store, appearance: appearance, onEscape: onShelve)
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                NoteActionsButton(state: titlebarState, appearance: appearance, onActions: onActions)
            }
            .padding(.leading, 18).padding(.trailing, 12).padding(.top, 4).padding(.bottom, 8)
        }
    }
}

@MainActor
final class NoteTitlebarState: ObservableObject {
    @Published private(set) var isPointerInside = false
    @Published private(set) var showsShortcutHints = false
    @Published var isActionsPresented = false
    @Published var iconRequest = 0
    @Published var copiedAll = false
    weak var actionsAnchor: NSView?

    func setShortcutHints(_ value: Bool) {
        guard showsShortcutHints != value else { return }
        showsShortcutHints = value
    }

    func setPointerInside(_ value: Bool) {
        guard isPointerInside != value else { return }
        isPointerInside = value
    }
}

/// Only the header observes hover changes; the native editor is not rebuilt.
private struct NoteTitlebar: View {
    @ObservedObject private var shortcuts = ShortcutSettings.shared
    @ObservedObject private var languageSettings = LanguageSettings.shared
    @ObservedObject var store: NoteStore
    @ObservedObject var state: NoteTitlebarState
    var ink: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    @FocusState private var focusedAction: Action?
    @State private var isIconPickerPresented = false
    @State private var isIconHovered = false
    private enum Action: Hashable { case close, icon, pin, collapse, shelve }
    var onPin: () -> Void
    var onCollapse: () -> Void
    var onClose: () -> Void
    var onShelve: () -> Void
    var onColorMenu: (() -> NSMenu?)?
    private let closeButtonSize: CGFloat = 26
    private var controlsVisible: Bool { state.isPointerInside || state.showsShortcutHints || state.isActionsPresented || focusedAction != nil || voiceOverEnabled || isIconPickerPresented }
    private let buttonSize: CGFloat = 28

    var body: some View {
        HStack(spacing: 3) {
            NoteTitlebarButton(symbol: "xmark", label: String(localized: "Close Note", bundle: languageSettings.bundle), help: String(localized: "Close the note (⌘W)", bundle: languageSettings.bundle), isClose: true, buttonSize: closeButtonSize, ink: ink, shortcut: .shelve, showsHint: state.showsShortcutHints, action: onClose)
                .disabled(store.loadError != nil)
                .focused($focusedAction, equals: .close)
                .opacity(controlsVisible ? 1 : 0)
                .allowsHitTesting(controlsVisible)
            if store.isCollapsed { iconButton }
            WindowDragRegion(onDoubleClick: onCollapse, onContextMenu: onColorMenu,
                             hasCenteredIcon: !store.isCollapsed && (store.document.icon != nil || controlsVisible))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(alignment: .leading) {
                    if store.isCollapsed {
                        Text(collapsedTitle)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(ink)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .padding(.horizontal, 5)
                            .accessibilityLabel(String(localized: "Note title: \(collapsedTitle)", bundle: languageSettings.bundle))
                            // The native view underneath still owns dragging and double-clicks.
                            .allowsHitTesting(false)
                    }
                }
                .help((store.isCollapsed ? collapsedTitle + "\n" + String(localized: "Drag to move; double-click to expand", bundle: languageSettings.bundle) : String(localized: "Drag to move; double-click to collapse", bundle: languageSettings.bundle))
                      + "\n" + String(localized: "Right-click to change this note’s color", bundle: languageSettings.bundle))
            HStack(spacing: 0) {
                NoteTitlebarButton(symbol: store.document.isPinned ? "pin.fill" : "pin",
                                   label: store.document.isPinned ? String(localized: "Unpin Note", bundle: languageSettings.bundle) : String(localized: "Pin Note", bundle: languageSettings.bundle),
                                   help: String(localized: "Keep this note visible while using other apps", bundle: languageSettings.bundle),
                                   selected: store.document.isPinned, buttonSize: buttonSize, symbolSize: 14, ink: ink, shortcut: .pin, showsHint: state.showsShortcutHints, action: onPin)
                    .disabled(store.loadError != nil)
                    .focused($focusedAction, equals: .pin)
                NoteTitlebarButton(symbol: store.isCollapsed ? "chevron.down" : "chevron.up",
                                   label: store.isCollapsed ? String(localized: "Expand Note", bundle: languageSettings.bundle) : String(localized: "Collapse Note", bundle: languageSettings.bundle),
                                   help: store.isCollapsed ? String(localized: "Restore the original size", bundle: languageSettings.bundle) : String(localized: "Collapse to one line on the desktop", bundle: languageSettings.bundle),
                                   buttonSize: buttonSize, symbolSize: 16, ink: ink, shortcut: .collapse, showsHint: state.showsShortcutHints, action: onCollapse)
                    .disabled(store.loadError != nil)
                    .focused($focusedAction, equals: .collapse)
                NoteTitlebarButton(symbol: "tray.and.arrow.down", label: String(localized: "Shelve Note", bundle: languageSettings.bundle),
                                   help: String(localized: "Move to the screen edge, keeping content and position", bundle: languageSettings.bundle),
                                   buttonSize: buttonSize, symbolSize: 15, ink: ink, shortcut: .shelve, showsHint: state.showsShortcutHints, action: onShelve)
                    .disabled(store.loadError != nil)
                    .focused($focusedAction, equals: .shelve)
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 4)
            .background(ink.opacity(0.045), in: Capsule())
            .overlay(Capsule().strokeBorder(ink.opacity(0.12), lineWidth: 0.5))
            .opacity(controlsVisible ? 1 : 0)
            .allowsHitTesting(controlsVisible)
        }
        // Align the close circle's center with the text, preserving the block-handle gutter.
        .padding(.leading, NoteLayout.editorHorizontalInset - closeButtonSize / 2)
        .padding(.trailing, 8)
        .frame(height: NoteLayout.headerHeight)
        .overlay {
            // Center against the full window, independent of the unequal controls.
            if !store.isCollapsed { iconButton }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: controlsVisible)
        .onChange(of: store.isCollapsed) { _, _ in isIconPickerPresented = false }
        .onChange(of: store.document.isShelved) { _, shelved in if shelved { isIconPickerPresented = false } }
        .onChange(of: store.document.deletedAt) { _, date in if date != nil { isIconPickerPresented = false } }
        .onChange(of: store.loadError) { _, error in if error != nil { isIconPickerPresented = false } }
        .onChange(of: state.iconRequest) { _, _ in
            if store.loadError == nil, !store.document.isShelved { isIconPickerPresented = true }
        }
        .onChange(of: state.isActionsPresented) { _, presented in if presented { isIconPickerPresented = false } }
    }

    private var iconButton: some View {
        Button { isIconPickerPresented = true } label: {
            Group {
                if state.showsShortcutHints {
                    TitlebarShortcutHint(action: .icon, ink: ink)
                } else if let icon = store.document.icon {
                    Text(icon).font(.system(size: 18))
                } else {
                    Image(systemName: "face.smiling").font(.system(size: 15, weight: .regular))
                        .foregroundStyle(ink.opacity(0.65))
                }
            }
            .frame(width: 26, height: 28)
            .background(ink.opacity(isIconHovered ? 0.06 : 0), in: .rect(cornerRadius: 6))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(store.loadError != nil)
        .focused($focusedAction, equals: .icon)
        .onHover { isIconHovered = $0 }
        .opacity(store.document.icon != nil || controlsVisible ? 1 : 0)
        .allowsHitTesting(store.document.icon != nil || controlsVisible)
        .help(store.document.icon == nil ? String(localized: "Add Icon", bundle: languageSettings.bundle)
              : String(localized: "Change Icon", bundle: languageSettings.bundle))
        .accessibilityLabel(store.document.icon == nil ? String(localized: "Add Icon", bundle: languageSettings.bundle)
                            : String(localized: "Change Icon", bundle: languageSettings.bundle))
        .accessibilityValue(store.document.icon ?? String(localized: "No Icon", bundle: languageSettings.bundle))
        .popover(isPresented: $isIconPickerPresented, arrowEdge: .bottom) {
            NoteIconPicker(selectedIcon: store.document.icon, onSelect: { icon in
                if store.setIcon(icon) { isIconPickerPresented = false }
            }, onClose: { isIconPickerPresented = false })
        }
    }

    private var collapsedTitle: String {
        for line in store.document.text.split(whereSeparator: \.isNewline) {
            let title = line.trimmingCharacters(in: .whitespaces)
            if !title.isEmpty { return title }
        }
        return String(localized: "Blank Note", bundle: languageSettings.bundle)
    }
}

private struct NoteTitlebarButton: View {
    @ObservedObject private var shortcuts = ShortcutSettings.shared
    var symbol: String
    var label: String
    var help: String
    var selected = false
    var isClose = false
    var buttonSize: CGFloat = 26
    var symbolSize: CGFloat = 14
    var ink: Color = .primary
    var shortcut: NoteAction? = nil
    var showsHint = false
    var action: () -> Void
    @State private var hovered = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            ZStack {
                if showsHint, isEnabled, let shortcut, !shortcut.activeKeycaps.isEmpty {
                    TitlebarShortcutHint(action: shortcut, ink: ink)
                } else if isClose {
                    Circle().fill(Color(red: 1, green: 0.37, blue: 0.35)).frame(width: 14, height: 14)
                    Image(systemName: symbol)
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(Color.black.opacity(0.55))
                        .opacity(hovered ? 1 : 0)
                } else {
                    Image(systemName: symbol)
                        .font(.system(size: symbolSize, weight: .regular))
                        .foregroundStyle(ink.opacity(isEnabled ? (selected || hovered ? 1 : 0.88) : 0.35))
                }
            }
            .frame(width: buttonSize, height: buttonSize)
            .background(ink.opacity(isClose || !isEnabled ? 0 : (hovered ? 0.06 : (selected ? 0.025 : 0))), in: Capsule())
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(help + (shortcut.flatMap { help.contains($0.activeKeycaps.joined()) ? nil : " (" + $0.activeKeycaps.joined() + ")" } ?? ""))
        .accessibilityLabel(label)
    }
}

private struct TitlebarShortcutHint: View {
    @ObservedObject private var shortcuts = ShortcutSettings.shared
    let action: NoteAction
    let ink: Color
    var body: some View {
        Text(action.activeHeldHint).font(.system(size: 11, weight: .semibold, design: .rounded))
            .lineLimit(1).minimumScaleFactor(0.5).frame(width: 22)
            .foregroundStyle(ink).frame(minWidth: 20, minHeight: 21)
            .background(ink.opacity(0.05), in: .rect(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(ink.opacity(0.25), lineWidth: 0.7))
            .accessibilityHidden(true)
    }
}

private struct NoteActionsButton: View {
    @ObservedObject private var shortcuts = ShortcutSettings.shared
    @ObservedObject private var language = LanguageSettings.shared
    @ObservedObject var state: NoteTitlebarState
    let appearance: NoteAppearance
    let onActions: () -> Void
    @State private var hovered = false
    private var ink: Color { Color(nsColor: appearance.secondaryTextColor) }
    var body: some View {
        Button(action: onActions) {
            HStack(spacing: 7) {
                Text(String(localized: "Actions", bundle: language.bundle)).font(.system(size: 11, weight: .medium))
                ShortcutKeycaps(keys: NoteAction.actions.activeKeycaps)
            }
            .padding(.horizontal, 9).frame(height: 29)
            .background(ink.opacity(hovered ? 0.09 : 0.045), in: Capsule())
            .overlay(Capsule().strokeBorder(ink.opacity(0.12), lineWidth: 0.5))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain).onHover { hovered = $0 }
        .background(NoteActionsAnchor(state: state))
        .help(String(localized: "Paper and app actions. Hold Command to reveal button shortcuts.", bundle: language.bundle))
        .accessibilityLabel(String(localized: "Actions", bundle: language.bundle) + " " + NoteAction.actions.activeKeycaps.joined())
        .foregroundStyle(ink)
    }
}

private struct NoteActionsAnchor: NSViewRepresentable {
    let state: NoteTitlebarState
    func makeNSView(context: Context) -> NSView {
        let view = AnchorView()
        state.actionsAnchor = view
        return view
    }
    func updateNSView(_ view: NSView, context: Context) { state.actionsAnchor = view }
    private final class AnchorView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
