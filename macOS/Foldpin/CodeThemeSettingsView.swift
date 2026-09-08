import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct CodeThemeSettingsView: View {
    @ObservedObject private var settings = CodeThemeSettings.shared
    @ObservedObject private var language = LanguageSettings.shared
    @State private var importing = false
    @State private var error: CodeThemeError?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(String(localized: "Code style", bundle: language.bundle), systemImage: "curlybraces")
                    .font(.system(size: 13, weight: .medium))
                Spacer()
                Picker(String(localized: "Code style", bundle: language.bundle),
                       selection: Binding(get: { settings.selection }, set: { settings.select($0) })) {
                    Section(String(localized: "Built-in", bundle: language.bundle)) {
                        ForEach(settings.choices.filter { !$0.imported }) { choice in
                            Text(choice.id == "github" ? String(localized: "GitHub · Follow app theme", bundle: language.bundle) : choice.name).tag(choice.id)
                        }
                    }
                    if settings.choices.contains(where: \.imported) {
                        Section(String(localized: "Imported", bundle: language.bundle)) {
                            ForEach(settings.choices.filter(\.imported)) { choice in
                                Text(verbatim: choice.name).tag(choice.id)
                            }
                        }
                    }
                }
                .labelsHidden()
                .frame(width: 240)
            }
            CodeStylePreview(theme: settings.theme, backgroundOpacity: settings.backgroundOpacity)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 12) {
                    Text(String(localized: "Background opacity", bundle: language.bundle))
                        .font(.system(size: 12))
                    Slider(value: Binding(get: { settings.backgroundOpacity }, set: { settings.setBackgroundOpacity($0) }),
                           in: 0...1, step: 0.01) {
                        Text(String(localized: "Background opacity", bundle: language.bundle))
                    }
                    .labelsHidden()
                    .accessibilityValue(settings.backgroundOpacity.formatted(.percent.precision(.fractionLength(0)).locale(language.locale)))
                    Text(settings.backgroundOpacity, format: .percent.precision(.fractionLength(0)))
                        .font(.system(size: 12).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 42, alignment: .trailing)
                }
                Text(String(localized: "0% is transparent; 100% uses the theme background. Text stays unchanged.", bundle: language.bundle))
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 12) {
                Button(String(localized: "Import theme…", bundle: language.bundle), action: chooseTheme)
                if settings.selectedIsImported {
                    Button(String(localized: "Remove imported theme", bundle: language.bundle)) {
                        do { try settings.removeSelectedImport() }
                        catch { self.error = .storage }
                    }
                }
                if importing { ProgressView().controlSize(.small) }
                Spacer()
            }
            .disabled(importing)
            Text(String(localized: "VS Code (.json / .jsonc) and TextMate (.tmTheme). Changes apply immediately to code blocks only.", bundle: language.bundle))
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text(String(localized: "Common syntax colors and font styles are supported; advanced semantic highlighting may differ.", bundle: language.bundle))
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .alert(String(localized: "Code style", bundle: language.bundle), isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button(String(localized: "OK", bundle: language.bundle)) { error = nil }
        } message: {
            Text(error?.message(bundle: language.bundle) ?? "")
        }
    }

    private func chooseTheme() {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Import code theme", bundle: language.bundle)
        panel.allowedContentTypes = [.json, UTType(filenameExtension: "jsonc") ?? .data, UTType(filenameExtension: "tmTheme") ?? .data]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.begin { response in
            guard response == .OK, let file = panel.url else { return }
            load(file)
        }
    }

    private func load(_ file: URL, folder: URL? = nil) {
        importing = true
        Task { @MainActor in
            let permissionURL = folder ?? file
            let scoped = permissionURL.startAccessingSecurityScopedResource()
            defer {
                if scoped { permissionURL.stopAccessingSecurityScopedResource() }
                importing = false
            }
            do {
                let definition = try await Task.detached(priority: .userInitiated) {
                    try CodeThemeLoader.load(file, allowedDirectory: folder)
                }.value
                try settings.install(definition)
            } catch CodeThemeError.companionFolderRequired {
                chooseCompanionFolder(for: file)
            } catch let failure as CodeThemeError {
                error = failure
            } catch {
                self.error = .invalid
            }
        }
    }

    private func chooseCompanionFolder(for file: URL) {
        let panel = NSOpenPanel()
        panel.message = CodeThemeError.companionFolderRequired.message(bundle: language.bundle)
        panel.directoryURL = file.deletingLastPathComponent()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.begin { response in
            guard response == .OK, let folder = panel.url else { return }
            load(file, folder: folder)
        }
    }
}

private struct CodeStylePreview: View {
    let theme: NativeCodeTheme
    let backgroundOpacity: Double
    @State private var preview: AttributedString?
    var body: some View {
        let sample = NoteContent(blocks: [NoteBlock(kind: .code,
            text: "// Foldpin\nconst message = \"Hello, world!\";\nfunction greet() { return 42; }", language: .javascript)])
        Text(preview ?? AttributedString(sample.plainText))
            .font(.system(size: 13, design: .monospaced))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 10)
            .background(Color(nsColor: theme.background).opacity(backgroundOpacity), in: .rect(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(nsColor: theme.border), lineWidth: 0.75))
            .accessibilityHidden(true)
            .task(id: ObjectIdentifier(theme)) {
                _ = await CodeSyntaxEngine.shared.analyze(sample.blocks[0].text, language: .javascript)
                guard !Task.isCancelled else { return }
                preview = AttributedString(BlockTextCodec.render(sample, color: .labelColor, width: 460,
                    theme: theme, cachedSyntaxOnly: true, image: { _ in nil }))
            }
    }
}
