import SwiftUI

struct AppearanceSettingsView: View {
    @AppStorage(NoteAppearance.preferenceKey) private var appearance: NoteAppearance = .paper
    @ObservedObject private var languageSettings = LanguageSettings.shared
    @ObservedObject private var themeSettings = ThemeSettings.shared
    @ObservedObject private var style = NoteStyleSettings.shared
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var families: [String] = []
    @State private var codeFamilies: [String] = []

    var body: some View {
        Form {
            Section {
                Picker(readinessText("Theme"), selection: Binding(get: { themeSettings.selection }, set: { themeSettings.select($0) })) {
                    ForEach(AppTheme.allCases) { theme in
                        Text(theme.title(bundle: languageSettings.bundle)).tag(theme)
                    }
                }
            }
            Section(readinessText("Note material")) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(NoteAppearance.allCases) { choice in
                        Button { appearance = choice } label: {
                            VStack(spacing: 8) {
                                AppearancePreview(appearance: choice).frame(height: 152)
                                HStack {
                                    Text(choice.title(bundle: languageSettings.bundle))
                                    Spacer()
                                    Image(systemName: appearance == choice ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(appearance == choice ? Color.accentColor : Color.secondary)
                                }.padding(.horizontal, 8).padding(.bottom, 8)
                            }
                            .contentShape(.rect)
                            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(appearance == choice ? Color.accentColor : Color.secondary.opacity(0.2), lineWidth: appearance == choice ? 2 : 1))
                        }.buttonStyle(.plain)
                        .accessibilityLabel(choice.title(bundle: languageSettings.bundle))
                        .accessibilityAddTraits(appearance == choice ? .isSelected : [])
                        .frame(maxWidth: .infinity)
                    }
                }
                if appearance == .translucent {
                    Picker(readinessText("Glass effect"), selection: binding(\.clearGlass)) {
                        Text(readinessText("Standard glass")).tag(false)
                        Text(readinessText("Clear glass")).tag(true)
                    }
                    .disabled(reduceTransparency || contrast == .increased)
                }
                valueSlider("Note background opacity", value: appearance == .paper ? binding(\.paperOpacity) : binding(\.glassOpacity), range: appearance == .paper ? 0.2...1 : 0...1, step: 0.01, percent: true)
                    .disabled(reduceTransparency || contrast == .increased)
                Text(readinessText("Only the background fades. Text and controls stay opaque. Glass blur is managed by macOS."))
                    .font(.caption).foregroundStyle(.secondary)
                if reduceTransparency || contrast == .increased {
                    Text(readinessText("Glass uses a solid background to match your accessibility settings."))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text(readinessText("Right-click a note’s title bar to choose a color for that note."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section(readinessText("Text layout")) {
                fontPicker("Body font", value: typographyBinding(\.bodyFamily), choices: families)
                valueSlider("Body font size", value: typographyBinding(\.bodySize), range: 11...28, step: 1)
                valueSlider("Line spacing", value: typographyBinding(\.lineSpacing), range: 0...12, step: 1)
                VStack(alignment: .leading, spacing: 6) {
                    Text(readinessText("Keep that thought")).font(Font(style.bodyFont(weight: .semibold)))
                    Text(readinessText("Jot it. Pin it. Fold it away.") + "\n" + readinessText("Saved on this Mac"))
                        .font(Font(style.bodyFont())).lineSpacing(style.values.typography.lineSpacing)
                }.padding(.vertical, 8)
                Text(readinessText("Applies to existing notes immediately. Your content and undo history stay unchanged."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section(readinessText("Code style")) {
                fontPicker("Code font", value: typographyBinding(\.codeFamily), choices: codeFamilies)
                valueSlider("Code font size", value: typographyBinding(\.codeSize), range: 10...24, step: 1)
                CodeThemeSettingsView()
            }
            Section {
                Button(readinessText("Reset note appearance adjustments")) { style.update { $0 = NoteStylePreferences() } }
            }
        }.formStyle(.grouped)
        .task {
            guard families.isEmpty else { return }
            families = NSFontManager.shared.availableFontFamilies.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            codeFamilies = families.filter { NSFontManager.shared.font(withFamily: $0, traits: [], weight: 5, size: 13)?.isFixedPitch == true }
        }
    }
    private func binding<T>(_ key: WritableKeyPath<NoteStylePreferences, T>) -> Binding<T> {
        Binding(get: { style.values[keyPath: key] }, set: { value in style.update { $0[keyPath: key] = value } })
    }
    private func typographyBinding<T>(_ key: WritableKeyPath<NoteTypography, T>) -> Binding<T> {
        Binding(get: { style.values.typography[keyPath: key] }, set: { value in style.update { $0.typography[keyPath: key] = value } })
    }
    private func fontPicker(_ title: String, value: Binding<String>, choices: [String]) -> some View {
        Picker(readinessText(title), selection: value) {
            Text(readinessText("System font")).tag("")
            if !value.wrappedValue.isEmpty && !choices.contains(value.wrappedValue) {
                Text(value.wrappedValue).tag(value.wrappedValue)
            }
            ForEach(choices, id: \.self) { Text(verbatim: $0).tag($0) }
        }
    }
    private func valueSlider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double, percent: Bool = false) -> some View {
        HStack {
            Text(readinessText(title)).frame(width: 140, alignment: .leading)
            Slider(value: value, in: range, step: step).accessibilityLabel(readinessText(title))
            Text(percent ? value.wrappedValue.formatted(.percent.precision(.fractionLength(0)).locale(languageSettings.locale)) : value.wrappedValue.formatted(.number.precision(.fractionLength(0)).locale(languageSettings.locale)))
                .monospacedDigit().foregroundStyle(.secondary).frame(width: 42, alignment: .trailing)
        }
    }
}

/// A small native preview of each style, using sample text rather than the user's note.
private struct AppearancePreview: View {
    @ObservedObject private var languageSettings = LanguageSettings.shared
    @ObservedObject private var style = NoteStyleSettings.shared
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
            Text(String(localized: "Keep that thought", bundle: languageSettings.bundle)).font(Font(style.bodyFont(size: min(17, style.values.typography.bodySize), weight: .medium)))
            Text(String(localized: "Jot it. Pin it. Fold it away.", bundle: languageSettings.bundle))
                .font(Font(style.bodyFont(size: min(15, style.values.typography.bodySize - 2)))).foregroundStyle(secondaryInk).padding(.top, 7)
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
