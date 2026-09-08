import SwiftUI

struct ContentView: View {
    @ObservedObject private var languageSettings = LanguageSettings.shared
    @ObservedObject var store: NoteStore
    @AppStorage(NoteAppearance.preferenceKey) private var appearance: NoteAppearance = .paper
    var onPin: () -> Void
    var onCollapse: () -> Void
    var onShelve: () -> Void
    var onRetryLoad: () -> Void
    var onRevealError: () -> Void

    var body: some View {
        GeometryReader { geometry in
            let expandedHeight = store.isCollapsed ? (store.document.frame?.height ?? 340) : geometry.size.height
            let bodyHeight = max(expandedHeight - NoteLayout.headerHeight,
                                 NoteLayout.minimumExpandedHeight - NoteLayout.headerHeight)
            VStack(spacing: 0) {
                titlebar
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
        .background { NoteSheetFill(appearance: appearance).allowsHitTesting(false) }
        .clipShape(.rect(cornerRadius: NoteWindowStyle.cornerRadius))
        .ignoresSafeArea(.container, edges: .top)
        .environment(\.locale, languageSettings.locale)
        .onChange(of: store.saveError) { _, error in if error != nil { onRevealError() } }
        .onChange(of: store.loadError) { _, error in if error != nil { onRevealError() } }
    }

    private var titlebar: some View {
        HStack(spacing: 3) {
            NoteTitlebarButton(symbol: "xmark", label: String(localized: "Close Note", bundle: languageSettings.bundle), help: String(localized: "Close the note and keep it on the shelf (⌘W)", bundle: languageSettings.bundle), action: onShelve)
                .disabled(store.loadError != nil)
            WindowDragRegion(onDoubleClick: onCollapse)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(alignment: .leading) {
                    if store.isCollapsed {
                        Text(collapsedTitle)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .padding(.horizontal, 5)
                            .accessibilityLabel(String(localized: "Note title: \(collapsedTitle)", bundle: languageSettings.bundle))
                            // The native view underneath still owns dragging and double-clicks.
                            .allowsHitTesting(false)
                    }
                }
                .help(store.isCollapsed ? String(localized: "\(collapsedTitle)\nDrag to move; double-click or press ⌘M to expand", bundle: languageSettings.bundle) : String(localized: "Drag to move; double-click or press ⌘M to collapse", bundle: languageSettings.bundle))
            NoteTitlebarButton(symbol: store.document.isPinned ? "pin.fill" : "pin",
                               label: store.document.isPinned ? String(localized: "Unpin Note", bundle: languageSettings.bundle) : String(localized: "Pin Note", bundle: languageSettings.bundle),
                               help: String(localized: "Keep this note visible while using other apps", bundle: languageSettings.bundle),
                               selected: store.document.isPinned, action: onPin)
                .disabled(store.loadError != nil)
            NoteTitlebarButton(symbol: store.isCollapsed ? "chevron.down" : "chevron.up",
                               label: store.isCollapsed ? String(localized: "Expand Note", bundle: languageSettings.bundle) : String(localized: "Collapse Note", bundle: languageSettings.bundle),
                               help: store.isCollapsed ? String(localized: "Restore the original size (⌘M)", bundle: languageSettings.bundle) : String(localized: "Collapse to one line on the desktop (⌘M)", bundle: languageSettings.bundle), action: onCollapse)
                .disabled(store.loadError != nil)
            NoteTitlebarButton(symbol: "tray.and.arrow.down", label: String(localized: "Shelve Note", bundle: languageSettings.bundle),
                               help: String(localized: "Move to the screen edge, keeping content and position", bundle: languageSettings.bundle), action: onShelve)
                .disabled(store.loadError != nil)
        }
        .padding(.horizontal, 8)
        .frame(height: NoteLayout.headerHeight)
    }

    private var collapsedTitle: String {
        for line in store.document.text.split(whereSeparator: \.isNewline) {
            let title = line.trimmingCharacters(in: .whitespaces)
            if !title.isEmpty { return title }
        }
        return String(localized: "Blank Note", bundle: languageSettings.bundle)
    }

    private var noteBody: some View {
        VStack(spacing: 0) {
            Divider()
            if let message = store.loadError ?? store.saveError {
                VStack(alignment: .leading, spacing: 7) {
                    Text(message).font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
                    Button(store.loadError == nil ? String(localized: "Retry Save", bundle: languageSettings.bundle) : String(localized: "Retry Load", bundle: languageSettings.bundle)) {
                        if store.loadError == nil { store.flush() } else { onRetryLoad() }
                    }.font(.system(size: 11, weight: .medium))
                }
                .foregroundStyle(.primary)
                .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.red.opacity(0.12))
            }
            // The native block editor owns all empty-block hints.
            NoteEditor(store: store, appearance: appearance, onEscape: onShelve)
            HStack(spacing: 8) {
                Text(store.hotKeyWarning == nil ? store.shortcutLabel : String(localized: "Shortcut unavailable", bundle: languageSettings.bundle))
                    .help(store.hotKeyWarning ?? String(localized: "Show or shelve your note. Change the shortcut in the menu bar.", bundle: languageSettings.bundle))
                Spacer()
                Text(store.status)
                    .foregroundStyle(store.saveError == nil ? Color.secondary : Color.red)
                    .accessibilityLabel(String(localized: "Save status: \(store.status)", bundle: languageSettings.bundle))
            }
            .font(.system(size: 10)).foregroundStyle(.secondary)
            .padding(.top, 8).padding(.bottom, 11).padding(.horizontal, 18)
        }
    }
}

private struct NoteTitlebarButton: View {
    var symbol: String
    var label: String
    var help: String
    var selected = false
    var action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(selected || hovered ? .primary : .secondary)
                .frame(width: 26, height: 26)
                .background(Color.primary.opacity(selected ? 0.10 : (hovered ? 0.07 : 0)),
                            in: .rect(cornerRadius: 6))
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(help)
        .accessibilityLabel(label)
    }
}
