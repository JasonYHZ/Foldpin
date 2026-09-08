import SwiftUI

struct AppearanceSettingsView: View {
    @AppStorage(NoteAppearance.preferenceKey) private var appearance: NoteAppearance = .paper
    @ObservedObject private var languageSettings = LanguageSettings.shared
    @ObservedObject private var themeSettings = ThemeSettings.shared
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 7) {
                Text(String(localized: "Make yourself at home", bundle: languageSettings.bundle)).font(.system(size: 23, weight: .semibold))
                Text(String(localized: "Choose a look for your notes. Switch anytime.", bundle: languageSettings.bundle))
                    .font(.system(size: 13)).foregroundStyle(.secondary)
            }

            HStack(alignment: .top, spacing: 16) {
                ForEach(NoteAppearance.allCases) { choice in
                    Button { appearance = choice } label: {
                        VStack(alignment: .leading, spacing: 12) {
                            AppearancePreview(appearance: choice)
                                .frame(height: 152)
                            HStack {
                                Text(choice.title(bundle: languageSettings.bundle)).font(.system(size: 14, weight: .semibold))
                                Spacer()
                                Image(systemName: appearance == choice ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(appearance == choice ? Color.accentColor : Color.secondary)
                                    .font(.system(size: 18))
                            }
                            Text(choice.subtitle(bundle: languageSettings.bundle)).font(.system(size: 12)).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.background, in: .rect(cornerRadius: 16))
                        .overlay(RoundedRectangle(cornerRadius: 16)
                            .strokeBorder(appearance == choice ? Color.accentColor : Color.primary.opacity(0.12),
                                          lineWidth: appearance == choice ? 2 : 1))
                        .contentShape(.rect(cornerRadius: 16))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(choice.title(bundle: languageSettings.bundle))
                    .accessibilityValue(appearance == choice ? String(localized: "Selected", bundle: languageSettings.bundle) : String(localized: "Not selected", bundle: languageSettings.bundle))
                    .accessibilityHint(choice.subtitle(bundle: languageSettings.bundle))
                    .accessibilityAddTraits(appearance == choice ? .isSelected : [])
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                Text(String(localized: "Right-click a note’s title bar to choose a color for that note.", bundle: languageSettings.bundle))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Label(String(localized: "\(appearance.title(bundle: languageSettings.bundle)) applied · Preference saved", bundle: languageSettings.bundle), systemImage: "checkmark.circle")
                    .font(.system(size: 12, weight: .medium))
                Text(reduceTransparency || contrast == .increased
                     ? String(localized: "Glass uses a solid background to match your accessibility settings.", bundle: languageSettings.bundle)
                     : String(localized: "Glass reflects your desktop and adapts to light, dark, and accessibility settings.", bundle: languageSettings.bundle))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Label(String(localized: "Theme", bundle: languageSettings.bundle), systemImage: "circle.lefthalf.filled")
                    .font(.system(size: 13, weight: .medium))
                Picker(String(localized: "Theme", bundle: languageSettings.bundle),
                       selection: Binding(get: { themeSettings.selection }, set: { themeSettings.select($0) })) {
                    ForEach(AppTheme.allCases) { theme in
                        Text(theme.title(bundle: languageSettings.bundle)).tag(theme)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                Text(String(localized: "Applies immediately to notes and settings. Code blocks use the style selected below.", bundle: languageSettings.bundle))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            CodeThemeSettingsView()

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label {
                        Text(verbatim: "语言 / Language")
                    } icon: {
                        Image(systemName: "globe")
                    }
                    .font(.system(size: 13, weight: .medium))
                    Spacer()
                    Picker(selection: Binding(get: { languageSettings.selection },
                                              set: { languageSettings.select($0) })) {
                        ForEach(AppLanguage.allCases) { language in
                            Text(language.title(bundle: languageSettings.bundle)).tag(language)
                        }
                    } label: {
                        Text(verbatim: "语言 / Language")
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 170)
                }
                Text(String(localized: "Changes apply immediately and are saved automatically.", bundle: languageSettings.bundle))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(28)
        }
        .frame(width: 556, height: 720)
        .navigationTitle(String(localized: "Foldpin Settings", bundle: languageSettings.bundle))
        .environment(\.locale, languageSettings.locale)
        .onAppear { languageSettings.refresh() }
    }
}

/// A small native preview of each style, using sample text rather than the user's note.
private struct AppearancePreview: View {
    @ObservedObject private var languageSettings = LanguageSettings.shared
    var appearance: NoteAppearance
    private var secondaryInk: Color { Color(nsColor: appearance.secondaryTextColor) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Image(systemName: "xmark").font(.system(size: 9)).foregroundStyle(secondaryInk)
                Spacer()
                HStack(spacing: 12) {
                    Image(systemName: "pin")
                    Image(systemName: "chevron.up")
                    Image(systemName: "tray.and.arrow.down")
                }
                .font(.system(size: 10)).padding(7)
            }
            .padding(.bottom, 15)
            Text(String(localized: "Keep that thought", bundle: languageSettings.bundle)).font(.system(size: 13, weight: .medium))
            Text(String(localized: "Jot it. Pin it. Fold it away.", bundle: languageSettings.bundle))
                .font(.system(size: 11)).foregroundStyle(secondaryInk).padding(.top, 7)
            Spacer(minLength: 10)
            Text(String(localized: "Saved on this Mac", bundle: languageSettings.bundle)).font(.system(size: 9)).foregroundStyle(secondaryInk)
        }
        .foregroundStyle(Color(nsColor: appearance.textColor))
        .padding(14)
        .modifier(NoteSheetSurface(appearance: appearance, cornerRadius: 12))
        .padding(8)
        .background {
            // A shared backdrop makes the actual material difference visible.
            LinearGradient(colors: [Color(red: 0.43, green: 0.66, blue: 0.64),
                                    Color(red: 0.57, green: 0.56, blue: 0.76),
                                    Color(red: 0.83, green: 0.66, blue: 0.53)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
        }
        .clipShape(.rect(cornerRadius: 12))
        .accessibilityHidden(true)
    }
}
