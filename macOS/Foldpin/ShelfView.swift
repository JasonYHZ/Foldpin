import SwiftUI

struct EdgeView: View {
    @ObservedObject private var languageSettings = LanguageSettings.shared
    @AppStorage(NoteAppearance.preferenceKey) private var appearance: NoteAppearance = .paper
    var onOpen: () -> Void
    var body: some View {
        Button(action: onOpen) {
            VStack(spacing: 8) {
                Image(systemName: "rectangle.stack").font(.system(size: 13))
                Text(verbatim: "1").font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(appearance == .paper ? Color(nsColor: NotePalette.edgeText) : Color.primary)
            .frame(width: 34, height: 84)
            .background(appearance == .paper ? Color(nsColor: NotePalette.edgeBackground) : .clear, in: RoundedRectangle(cornerRadius: 10))
            .modifier(NoteControlSurface(appearance: appearance))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.12)))
        }
        .buttonStyle(.plain)
        .help(String(localized: "Open shelf, 1 note", bundle: languageSettings.bundle))
        .accessibilityLabel(String(localized: "Open shelf, 1 note", bundle: languageSettings.bundle))
        .environment(\.locale, languageSettings.locale)
    }
}

struct ShelfView: View {
    @ObservedObject private var languageSettings = LanguageSettings.shared
    @ObservedObject var store: NoteStore
    @AppStorage(NoteAppearance.preferenceKey) private var appearance: NoteAppearance = .paper
    var onOpen: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(String(localized: "Shelf", bundle: languageSettings.bundle)).font(.system(size: 17, weight: .semibold))
                Spacer()
                Text(String(localized: "1 note", bundle: languageSettings.bundle)).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Divider()
            Text(store.document.summary(bundle: languageSettings.bundle)).font(.system(size: 14, weight: .medium)).lineLimit(2)
            if !store.document.text.isEmpty {
                Text(store.document.text).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(3)
            }
            Button(action: onOpen) {
                Text(String(localized: "Put Back", bundle: languageSettings.bundle)).frame(maxWidth: .infinity).padding(.vertical, 5)
            }
            .buttonStyle(.borderedProminent).tint(Color(red: 0.38, green: 0.48, blue: 0.31))
            .keyboardShortcut(.defaultAction)
            Text(String(localized: "Your content, position, and pin setting are kept.", bundle: languageSettings.bundle))
                .font(.system(size: 10)).foregroundStyle(.secondary)
        }
        .padding(20).frame(width: 280)
        .environment(\.locale, languageSettings.locale)
    }
}
