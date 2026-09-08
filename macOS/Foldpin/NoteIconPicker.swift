import SwiftUI
import Combine

/// The picker is created only while choosing an icon. Search and keyboard
/// focus stay here; neither the query nor a cancelled choice edits the note.
struct NoteIconPicker: View {
    @ObservedObject private var languageSettings = LanguageSettings.shared
    let selectedIcon: String?
    let onSelect: (String?) -> Void
    let onClose: () -> Void
    @State private var query = ""
    @State private var grid = NoteEmojiGridLayout.browsing
    // The parent does not observe this publisher; only the category bar does.
    @State private var indicator = EmojiCategoryIndicator()
    @State private var contentRevision = 0
    @State private var pendingCategory: NoteEmojiCategory?
    @FocusState private var focus: EmojiPickerField?
    private var bundle: Bundle { languageSettings.bundle }
    private var usesChinese: Bool { languageSettings.configuration.identifier.hasPrefix("zh") }
    private var isSearching: Bool { !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        let selectedKey = selectedIcon.map(NoteEmojiCatalog.emojiKey)
        VStack(spacing: 0) {
            header
            ScrollViewReader { proxy in
                VStack(spacing: 0) {
                    searchField(proxy: proxy)
                        .padding(12)
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(grid.rows) { row in
                                emojiRow(row, selectedKey: selectedKey)
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.top, NoteEmojiGridLayout.topInset)
                        .padding(.bottom, NoteEmojiGridLayout.bottomInset)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .onMoveCommand { moveFocus($0, proxy: proxy) }
                    }
                    .onScrollGeometryChange(for: NoteEmojiCategory?.self) { geometry in
                        // One viewport snapshot, one category; section cells no
                        // longer compete to publish their own geometry guesses.
                        grid.category(at: geometry.visibleRect.minY)
                    } action: { _, category in
                        indicator.update(category)
                    }
                    .frame(height: 280)
                    Divider()
                    EmojiCategoryBar(indicator: indicator, isSearching: isSearching,
                                     bundle: bundle, focus: $focus) { jump(to: $0, proxy: proxy) }
                }
                .onAppear { refreshGrid(proxy: proxy); focus = .search }
                .onChange(of: query) { _, _ in refreshGrid(proxy: proxy) }
            }
        }
        .frame(width: 376)
        .environment(\.locale, languageSettings.locale)
        .onExitCommand(perform: onClose)
    }

    private func emojiRow(_ row: NoteEmojiGridLayout.Row, selectedKey: String?) -> some View {
        Group {
            switch row.kind {
            case .heading:
                Text(row.category?.title(bundle: bundle) ?? String(localized: "Search Results", bundle: bundle))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .accessibilityAddTraits(.isHeader)
            case .empty:
                Text(String(localized: "No emoji found. Try another keyword.", bundle: bundle))
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .lineLimit(2)
            case .emoji:
                HStack(spacing: 3) {
                    ForEach(row.items) { item in
                        NoteEmojiButton(entry: item.entry, chinese: usesChinese,
                                        selected: selectedKey == NoteEmojiCatalog.emojiKey(item.entry.emoji)) {
                            onSelect(item.entry.emoji)
                        }
                        .focused($focus, equals: .emoji(item.id))
                    }
                }
            }
        }
        .frame(height: NoteEmojiGridLayout.rowHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .id(row.id)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text(String(localized: "Emoji", bundle: bundle))
                .font(.system(size: 14, weight: .semibold))
            Spacer()
            if selectedIcon != nil {
                Button(String(localized: "Remove Icon", bundle: bundle)) { onSelect(nil) }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .font(.system(size: 12))
            }
            Button(action: onClose) { Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)).frame(width: 20, height: 20) }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .help(String(localized: "Close", bundle: bundle))
                .accessibilityLabel(String(localized: "Close", bundle: bundle))
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .overlay(alignment: .bottom) { Divider() }
    }

    private func searchField(proxy: ScrollViewProxy) -> some View {
        HStack(spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(String(localized: "Search or paste an emoji…", bundle: bundle), text: $query)
                    .textFieldStyle(.plain)
                    .focused($focus, equals: .search)
                    .accessibilityLabel(String(localized: "Search Emoji", bundle: bundle))
                    .onSubmit {
                        guard !hasMarkedText, let first = grid.firstItem else { return }
                        onSelect(first.entry.emoji)
                    }
                    .onKeyPress(.downArrow) {
                        guard !hasMarkedText, let first = grid.firstItem else { return .ignored }
                        focusEmoji(first, proxy: proxy)
                        return .handled
                    }
                if !query.isEmpty {
                    Button { query = ""; focus = .search } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(String(localized: "Clear Search", bundle: bundle))
                }
            }
            .font(.system(size: 13))
            .padding(.horizontal, 10).frame(height: 32)
            .background(Color.primary.opacity(0.035), in: .rect(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.primary.opacity(0.1), lineWidth: 1))
            Button {
                if let entry = NoteEmojiCatalog.shared.entries.randomElement() { onSelect(entry.emoji) }
            } label: {
                Image(systemName: "shuffle").font(.system(size: 14)).frame(width: 32, height: 32)
                    .background(Color.primary.opacity(0.035), in: .rect(cornerRadius: 7))
            }
            .buttonStyle(.plain)
            .help(String(localized: "Random Emoji", bundle: bundle))
            .accessibilityLabel(String(localized: "Random Emoji", bundle: bundle))
        }
    }

    private var hasMarkedText: Bool { (NSApp.keyWindow?.firstResponder as? NSTextView)?.hasMarkedText() == true }

    private func refreshGrid(proxy: ScrollViewProxy) {
        grid = isSearching ? NoteEmojiGridLayout(query: query) : .browsing
        contentRevision += 1
        let revision = contentRevision
        if case .emoji = focus { focus = .search }
        let target = pendingCategory
        pendingCategory = nil
        indicator.update(isSearching ? nil : (target ?? .common))
        let destination = target.flatMap { grid.sectionID(for: $0) } ?? grid.rows.first?.id
        // Only query changes replace content. Discard a queued jump if another
        // search has already replaced its rows before SwiftUI lays them out.
        DispatchQueue.main.async {
            guard revision == contentRevision, let destination else { return }
            proxy.scrollTo(destination, anchor: .top)
        }
    }

    private func jump(to target: NoteEmojiCategory, proxy: ScrollViewProxy) {
        if isSearching {
            pendingCategory = target
            query = ""
        } else if let id = grid.sectionID(for: target) {
            proxy.scrollTo(id, anchor: .top)
        }
    }

    private func focusEmoji(_ item: NoteEmojiGridLayout.Item, proxy: ScrollViewProxy) {
        guard let rowID = grid.rowID(for: item) else { return }
        proxy.scrollTo(rowID)
        let revision = contentRevision
        DispatchQueue.main.async {
            guard revision == contentRevision else { return }
            focus = .emoji(item.id)
        }
    }

    private func moveFocus(_ direction: MoveCommandDirection, proxy: ScrollViewProxy) {
        guard case .emoji(let id) = focus else { return }
        let move: NoteEmojiGridLayout.Direction
        switch direction {
        case .left: move = .left
        case .right: move = .right
        case .up: move = .up
        case .down: move = .down
        @unknown default: return
        }
        if let item = grid.neighbor(of: id, direction: move) {
            focusEmoji(item, proxy: proxy)
        } else {
            focus = direction == .left || direction == .up ? .search : .category(indicator.category ?? .common)
        }
    }
}

private enum EmojiPickerField: Hashable { case search, emoji(String), category(NoteEmojiCategory) }

@MainActor
private final class EmojiCategoryIndicator: ObservableObject {
    @Published private(set) var category: NoteEmojiCategory? = .common
    func update(_ value: NoteEmojiCategory?) {
        guard value != category else { return }
        category = value
    }
}

private struct EmojiCategoryBar: View {
    @ObservedObject var indicator: EmojiCategoryIndicator
    let isSearching: Bool
    let bundle: Bundle
    var focus: FocusState<EmojiPickerField?>.Binding
    let onJump: (NoteEmojiCategory) -> Void

    var body: some View {
        HStack(spacing: 3) {
            ForEach(NoteEmojiCategory.allCases, id: \.self) { item in
                let selected = indicator.category == item && !isSearching
                Button { onJump(item) } label: {
                    Image(systemName: item.symbol).font(.system(size: 16, weight: .regular))
                        .foregroundStyle(selected ? .primary : .secondary)
                        .frame(width: 32, height: 32)
                        .background(Color.primary.opacity(selected ? 0.07 : 0), in: .rect(cornerRadius: 7))
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .focused(focus, equals: .category(item))
                .help(item.title(bundle: bundle))
                .accessibilityLabel(item.title(bundle: bundle))
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(.vertical, 9)
    }
}

private struct NoteEmojiButton: View {
    let entry: NoteEmoji
    let chinese: Bool
    let selected: Bool
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Text(entry.emoji).font(.system(size: 23))
                .frame(width: 32, height: 32)
                .background(Color.primary.opacity(hovered ? 0.07 : 0), in: .rect(cornerRadius: 6))
                .overlay {
                    if selected { RoundedRectangle(cornerRadius: 6).strokeBorder(Color.accentColor, lineWidth: 1.5) }
                }
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        // Hover only changes this cell's appearance, never keyboard selection.
        .onHover { hovered = $0 }
        .help(entry.title(chinese: chinese))
        .accessibilityLabel(entry.title(chinese: chinese))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
