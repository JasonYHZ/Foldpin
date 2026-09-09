import SwiftUI

struct EdgeView: View {
    @ObservedObject private var languageSettings = LanguageSettings.shared
    @ObservedObject var library: NoteLibrary
    @AppStorage(NoteAppearance.preferenceKey) private var appearance: NoteAppearance = .paper
    var onOpen: () -> Void
    var body: some View {
        Button(action: onOpen) {
            VStack(spacing: 8) {
                Image(systemName: "rectangle.stack").font(.system(size: 13))
                Text(library.entries.count.formatted()).font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(appearance == .paper ? Color(nsColor: NotePalette.edgeText) : Color.primary)
            .frame(width: 34, height: 84)
            .background(appearance == .paper ? Color(nsColor: NotePalette.edgeBackground) : .clear, in: RoundedRectangle(cornerRadius: 10))
            .modifier(NoteControlSurface(appearance: appearance))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.12)))
        }
        .buttonStyle(.plain)
        .help(String(localized: "Open Shelf", bundle: languageSettings.bundle))
        .accessibilityLabel(String(localized: "Open Shelf", bundle: languageSettings.bundle))
        .accessibilityValue(library.entries.count.formatted())
        .environment(\.locale, languageSettings.locale)
    }
}

struct ShelfView: View {
    @ObservedObject private var languageSettings = LanguageSettings.shared
    @ObservedObject var library: NoteLibrary
    var onOpen: (UUID) -> Void
    var onNew: () -> Void
    var onRetry: () -> Void
    var onRestore: (UUID) -> Void = { _ in }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(String(localized: "Shelf", bundle: languageSettings.bundle)).font(.system(size: 17, weight: .semibold))
                Text(library.entries.count.formatted()).font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Button(action: onNew) { Image(systemName: "plus") }
                    .buttonStyle(.borderless)
                    .help(String(localized: "New Note", bundle: languageSettings.bundle))
                    .accessibilityLabel(String(localized: "New Note", bundle: languageSettings.bundle))
                    .disabled(!library.canCreate)
            }
            if let error = library.message(bundle: languageSettings.bundle) {
                Text(error).font(.system(size: 11)).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                Button(String(localized: "Retry Load", bundle: languageSettings.bundle), action: onRetry)
            }
            Divider()
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(library.entries) { entry in
                        ShelfNoteRow(store: entry.store, onOpen: { onOpen(entry.id) })
                    }
                    if !library.deletedEntries.isEmpty {
                        DisclosureGroup {
                            ForEach(library.deletedEntries) { entry in
                                DeletedNoteRow(store: entry.store, onRestore: { onRestore(entry.id) })
                            }
                        } label: {
                            Text(String(localized: "Recently Deleted", bundle: languageSettings.bundle) + " (\(library.deletedEntries.count))")
                                .font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                        }.padding(.top, 8)
                    }
                }
            }
            .frame(height: min(360, max(160, CGFloat(library.entries.count + library.deletedEntries.count) * 100)))
            Text(String(localized: "Your content, position, and pin setting are kept.", bundle: languageSettings.bundle))
                .font(.system(size: 10)).foregroundStyle(.secondary)
        }
        .padding(18).frame(width: 320)
        .environment(\.locale, languageSettings.locale)
    }
}

private struct DeletedNoteRow: View {
    @ObservedObject var store: NoteStore
    @ObservedObject private var language = LanguageSettings.shared
    var onRestore: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(store.document.summary(bundle: language.bundle)).font(.system(size: 12)).lineLimit(1)
                Spacer()
                Button(String(localized: "Restore Note", bundle: language.bundle), action: onRestore)
                    .buttonStyle(.borderless).font(.system(size: 11))
            }
            if let error = store.saveError { Text(error).font(.system(size: 10)).foregroundStyle(.red) }
        }.padding(8)
    }
}

private struct ShelfNoteRow: View {
    @ObservedObject private var languageSettings = LanguageSettings.shared
    @ObservedObject var store: NoteStore
    var onOpen: () -> Void
    private var preview: String {
        store.document.content.blocks.lazy.map { String($0.plainText.prefix(180)) }
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.prefix(2).joined(separator: "\n")
    }
    var body: some View {
        let title = preview.split(whereSeparator: \.isNewline).first.map(String.init)
            ?? String(localized: "Blank Note", bundle: languageSettings.bundle)
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    if let icon = store.document.icon {
                        Text(icon).font(.system(size: 16)).accessibilityHidden(true)
                    }
                    Text(store.loadError == nil ? title : String(localized: "Could not load", bundle: languageSettings.bundle))
                        .font(.system(size: 13, weight: .medium)).lineLimit(1)
                    Spacer(minLength: 4)
                    if store.document.isPinned { Image(systemName: "pin.fill").font(.system(size: 10)) }
                }
                if store.loadError == nil && !preview.isEmpty {
                    Text(preview).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                }
                Text(store.document.isShelved ? String(localized: "On Shelf", bundle: languageSettings.bundle)
                     : String(localized: "On Desktop", bundle: languageSettings.bundle))
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(10)
            .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
