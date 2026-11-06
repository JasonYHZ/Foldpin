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
                                AppearancePreview(appearance: choice).frame(height: 230)
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
                    Picker(readinessText("Glass style"), selection: binding(\.clearGlass)) {
                        Text(readinessText("Standard glass")).tag(false)
                        Text(readinessText("Clear glass")).tag(true)
                    }
                    .disabled(reduceTransparency || contrast == .increased)
                }
                if appearance == .translucent {
                    Text(readinessText("macOS manages the glass effect. Choose Standard for a stronger material appearance or Clear for a lighter appearance."))
                        .font(.caption).foregroundStyle(.secondary)
                    glassBalanceSlider
                        .disabled(reduceTransparency || contrast == .increased)
                    Text(readinessText("At 50%, use native glass. Move left to reduce glass, or right to add a reading backdrop."))
                        .font(.caption).foregroundStyle(.secondary)
                    valueSlider("Color intensity", value: binding(\.glassColorIntensity), range: 0...1, step: 0.01, percent: true)
                        .disabled(reduceTransparency || contrast == .increased)
                    Text(readinessText("Adjusts the color tint on glass notes. Your note colors stay saved."))
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    valueSlider("Paper opacity", value: binding(\.paperOpacity), range: 0.2...1, step: 0.01, percent: true)
                        .disabled(reduceTransparency || contrast == .increased)
                }
                if reduceTransparency || contrast == .increased {
                    Text(readinessText("macOS accessibility settings are using a solid background. Your appearance preferences are saved."))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Button(readinessText("Reset surface settings")) {
                    style.update { $0.resetSurface() }
                    appearance = .paper
                }
                Text(readinessText("Right-click a note’s title bar to choose a color for that note."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section(readinessText("Titlebar and density")) {
                Picker(readinessText("Titlebar controls"), selection: binding(\.titlebarVisibility)) {
                    Text(readinessText("Automatic")).tag(NoteTitlebarVisibility.automatic)
                    Text(readinessText("Always visible")).tag(NoteTitlebarVisibility.alwaysVisible)
                }
                Picker(readinessText("Content density"), selection: binding(\.contentDensity)) {
                    Text(readinessText("Compact")).tag(NoteContentDensity.compact)
                    Text(readinessText("Standard")).tag(NoteContentDensity.standard)
                    Text(readinessText("Comfortable")).tag(NoteContentDensity.comfortable)
                }
                Button(readinessText("Reset titlebar and density")) { style.update { $0.resetTitlebarAndDensity() } }
            }
            Section(readinessText("Text layout")) {
                fontPicker("Body font", value: typographyBinding(\.bodyFamily), choices: families)
                valueSlider("Body font size", value: typographyBinding(\.bodySize), range: 11...28, step: 1)
                valueSlider("Additional line spacing", value: typographyBinding(\.lineSpacing), range: 0...12, step: 1, unit: " pt")
                VStack(alignment: .leading, spacing: 6) {
                    Text(readinessText("Keep that thought")).font(Font(style.bodyFont(weight: .semibold)))
                    Text(readinessText("Jot it. Pin it. Fold it away.") + "\n" + readinessText("Saved on this Mac"))
                        .font(Font(style.bodyFont())).lineSpacing(style.values.typography.lineSpacing)
                }.padding(.vertical, 8)
                Text(readinessText("Applies to existing notes immediately. Your content and undo history stay unchanged."))
                    .font(.caption).foregroundStyle(.secondary)
                Button(readinessText("Reset body typography")) { style.update { $0.resetBodyTypography() } }
            }
            Section(readinessText("Code style")) {
                fontPicker("Code font", value: typographyBinding(\.codeFamily), choices: codeFamilies)
                valueSlider("Code font size", value: typographyBinding(\.codeSize), range: 10...24, step: 1)
                CodeThemeSettingsView()
                Button(readinessText("Reset code typography")) { style.update { $0.resetCodeTypography() } }
            }
            Section(readinessText("New-note defaults")) {
                Picker(readinessText("Default note color"), selection: binding(\.defaultNoteColor)) {
                    ForEach(NoteColor.allCases, id: \.self) { color in
                        Text(color.title(bundle: languageSettings.bundle)).tag(color)
                    }
                }
                Picker(readinessText("New note size"), selection: binding(\.newNoteSize)) {
                    ForEach(NoteNewSize.allCases) { preset in
                        Text(sizeTitle(preset)).tag(preset)
                    }
                }
                Text(readinessText("For new notes. Existing notes keep their color and size."))
                    .font(.caption).foregroundStyle(.secondary)
                Button(readinessText("Reset new-note defaults")) { style.update { $0.resetNewNoteDefaults() } }
            }
        }.formStyle(.grouped)
        .task {
            guard families.isEmpty else { return }
            families = NSFontManager.shared.availableFontFamilies.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            codeFamilies = families.filter { NSFontManager.shared.font(withFamily: $0, traits: [], weight: 5, size: 13)?.isFixedPitch == true }
        }
    }
    private func sizeTitle(_ preset: NoteNewSize) -> String {
        switch preset {
        case .small: readinessText("Small")
        case .standard: readinessText("Standard")
        case .large: readinessText("Large")
        }
    }
    private func binding<T>(_ key: WritableKeyPath<NoteStylePreferences, T>) -> Binding<T> {
        Binding(get: { style.values[keyPath: key] }, set: { value in style.update { $0[keyPath: key] = value } })
    }
    private func typographyBinding<T>(_ key: WritableKeyPath<NoteTypography, T>) -> Binding<T> {
        Binding(get: { style.values.typography[keyPath: key] }, set: { value in style.update { $0.typography[keyPath: key] = value } })
    }
    private var glassSliderBinding: Binding<Double> {
        Binding(
            get: { (style.values.glassBalance + 1) / 2 },
            set: { value in style.update { $0.glassBalance = value * 2 - 1 } }
        )
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
    private var glassBalanceSlider: some View {
        VStack(spacing: 4) {
            HStack {
                Text(readinessText("Glass balance"))
                    .frame(width: 140, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                Slider(value: glassSliderBinding, in: 0...1, step: 0.01)
                    .accessibilityLabel(readinessText("Glass balance"))
                    .accessibilityValue(glassBalanceAccessibilityValue)
                Text(glassBalanceValue)
                    .monospacedDigit().foregroundStyle(.secondary)
                    .frame(width: 60, alignment: .trailing)
            }
            HStack {
                Text(readinessText("More transparent"))
                Spacer()
                Text(readinessText("Native glass"))
                Spacer()
                Text(readinessText("More backdrop"))
            }
            .font(.caption2).foregroundStyle(.secondary)
            .padding(.leading, 140)
            .padding(.trailing, 60)
        }
    }
    private var glassBalanceValue: String {
        glassSliderBinding.wrappedValue.formatted(.percent.precision(.fractionLength(0)).locale(languageSettings.locale))
    }
    private var glassBalanceAccessibilityValue: String {
        let balance = style.values.glassBalance
        let direction = readinessText(balance < 0 ? "More transparent" : balance > 0 ? "More backdrop" : "Native glass")
        return direction + " " + glassBalanceValue
    }
    private func valueSlider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double, percent: Bool = false, unit: String = "") -> some View {
        HStack {
            Text(readinessText(title)).frame(width: 140, alignment: .leading).fixedSize(horizontal: false, vertical: true)
            Slider(value: value, in: range, step: step).accessibilityLabel(readinessText(title))
                .accessibilityValue(percent ? value.wrappedValue.formatted(.percent.precision(.fractionLength(0)).locale(languageSettings.locale)) : value.wrappedValue.formatted(.number.locale(languageSettings.locale)) + unit)
            Text(percent ? value.wrappedValue.formatted(.percent.precision(.fractionLength(0)).locale(languageSettings.locale)) : value.wrappedValue.formatted(.number.precision(.fractionLength(0)).locale(languageSettings.locale)) + unit)
                .monospacedDigit().foregroundStyle(.secondary).frame(width: 50, alignment: .trailing)
        }
    }
}

/// A small native preview of each style, using sample text rather than the user's note.
private struct AppearancePreview: View {
    @ObservedObject private var languageSettings = LanguageSettings.shared
    @ObservedObject private var style = NoteStyleSettings.shared
    var appearance: NoteAppearance
    private var secondaryInk: Color { Color(nsColor: NotePalette.secondaryText(for: appearance.textColor)) }

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
            Label(String(localized: "Keep that thought", bundle: languageSettings.bundle), systemImage: "checkmark.square")
                .font(Font(style.bodyFont(size: 11))).padding(.top, 8)
            Text(verbatim: "let idea = \"Foldpin\"")
                .font(Font(style.codeFont(size: min(12, style.values.typography.codeSize))))
                .padding(.top, 8)
            Spacer(minLength: 0)
        }
        .foregroundStyle(Color(nsColor: appearance.textColor))
        .padding(14)
        // Show the actual default warm paper. Keep a blue sample for glass so
        // its independent color-intensity control has a visible reference.
        .modifier(NoteSheetSurface(appearance: appearance, cornerRadius: 12,
                                   color: appearance == .paper ? .original : .blue))
        .padding(16)
        .background {
            GeometryReader { geometry in
                ZStack(alignment: .topLeading) {
                    Color(nsColor: .windowBackgroundColor)
                    HStack(spacing: 0) {
                        Color(red: 0.82, green: 0.88, blue: 0.92)
                        Color(red: 0.16, green: 0.24, blue: 0.34)
                    }
                    Path { path in
                        for y in stride(from: 12.0, through: geometry.size.height, by: 20) {
                            path.move(to: CGPoint(x: 0, y: y))
                            path.addLine(to: CGPoint(x: geometry.size.width, y: y))
                        }
                    }.stroke(.white.opacity(0.5), lineWidth: 0.5)
                    VStack(alignment: .leading, spacing: 20) {
                        Text(verbatim: "Aa  •  0123456789").foregroundStyle(.black)
                        Text(verbatim: "Notes / Ideas / Tasks").foregroundStyle(.white)
                        Text(verbatim: "Aa  •  0123456789").foregroundStyle(.black)
                        Text(verbatim: "Notes / Ideas / Tasks").foregroundStyle(.white)
                    }.font(.system(size: 12, design: .monospaced)).padding(4)
                }
            }
        }
        .clipShape(.rect(cornerRadius: 12))
        .accessibilityHidden(true)
    }
}
