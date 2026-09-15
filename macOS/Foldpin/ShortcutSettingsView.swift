import SwiftUI
import AppKit

struct ShortcutSettingsView: View {
    @ObservedObject var settings: ShortcutSettings = .shared
    @ObservedObject private var language = LanguageSettings.shared
    @State var global = false
    private var bundle: Bundle { language.bundle }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Picker(String(localized: "Shortcut scope", bundle: bundle), selection: $global) {
                Text(String(localized: "In App", bundle: bundle)).tag(false)
                Text(String(localized: "Global", bundle: bundle)).tag(true)
            }.pickerStyle(.segmented)
            Text(global ? String(localized: "Available in other apps while Foldpin is running. You can change or clear each shortcut.", bundle: bundle)
                 : String(localized: "App actions work while Foldpin is active. Note and editor actions apply only to the focused note.", bundle: bundle))
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let error = settings.error ?? settings.globalError {
                Label(error, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true).accessibilityAddTraits(.updatesFrequently)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if global {
                        group(String(localized: "Global actions", bundle: bundle), ids: GlobalShortcutAction.allCases.map(\.id))
                        Text(String(localized: "Quick Recording creates a new note. Press again to finish and save the current recording. Microphone access is requested only when you start recording.", bundle: bundle))
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        if settings.globalError != nil {
                            Button(String(localized: "Retry", bundle: bundle)) { settings.registerGlobals() }
                        }
                    } else {
                        group(String(localized: "App actions", bundle: bundle), ids: ShortcutSettings.appActions.map { "note." + $0.rawValue })
                        group(String(localized: "Current Note", bundle: bundle), ids: ShortcutSettings.paperActions.map { "note." + $0.rawValue })
                        group(String(localized: "Current editor", bundle: bundle), ids: EditorShortcutAction.allCases.map(\.id))
                        Text(String(localized: "Copy, paste, undo, close, quit, and standard text formatting keep their system shortcuts. Slash, Return, and Tab remain editor input rules.", bundle: bundle))
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }.padding(.vertical, 4)
            }.frame(maxHeight: .infinity)
            Divider()
            HStack {
                Text(String(localized: "Changes apply immediately and are saved automatically.", bundle: bundle)).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(String(localized: "Restore Page Defaults", bundle: bundle)) {
                    settings.reset(global ? GlobalShortcutAction.allCases.map(\.id) : ShortcutSettings.localIDs)
                }
            }
        }.padding(24)
        .onChange(of: global) { _, _ in settings.error = nil }
    }
    private func group(_ title: String, ids: [String]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(.headline).padding(.bottom, 8)
            ForEach(ids, id: \.self) { id in
                HStack(spacing: 8) {
                    Text(settings.title(id)).font(.system(size: 12)).frame(maxWidth: .infinity, alignment: .leading)
                    ShortcutRecorderField(binding: settings.binding(id), label: settings.title(id),
                        capture: { settings.set($0, for: id) }, clear: { settings.set(.disabled, for: id) })
                        .frame(width: 130, height: 27)
                    Button { settings.set(.disabled, for: id) } label: { Image(systemName: "xmark.circle") }
                        .buttonStyle(.plain).disabled(settings.binding(id).code == nil)
                        .help(String(localized: "Clear Shortcut", bundle: bundle))
                        .accessibilityLabel(String(localized: "Clear Shortcut", bundle: bundle) + " · " + settings.title(id))
                    Button { settings.reset([id]) } label: { Image(systemName: "arrow.counterclockwise") }
                        .buttonStyle(.plain).disabled(settings.overrides[id] == nil)
                        .help(String(localized: "Restore Default", bundle: bundle))
                        .accessibilityLabel(String(localized: "Restore Default", bundle: bundle) + " · " + settings.title(id))
                }.padding(.vertical, 6)
                if id != ids.last { Divider() }
            }
        }.padding(12).background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct ShortcutRecorderField: NSViewRepresentable {
    let binding: ShortcutBinding
    let label: String
    let capture: (ShortcutBinding) -> Void
    let clear: () -> Void
    func makeNSView(context: Context) -> ShortcutRecorder { ShortcutRecorder() }
    func updateNSView(_ view: ShortcutRecorder, context: Context) {
        view.binding = binding; view.onCapture = capture; view.onClear = clear
        view.setAccessibilityLabel(label); view.refreshTitle()
    }
    static func dismantleNSView(_ view: ShortcutRecorder, coordinator: ()) { view.endRecording(restoreFocus: false) }
}


extension ShortcutBinding {
    var swiftUIShortcut: KeyboardShortcut? {
        guard let key = self.key.first, code != nil else { return nil }
        var flags: EventModifiers = []
        if modifiers.contains(.command) { flags.insert(.command) }
        if modifiers.contains(.control) { flags.insert(.control) }
        if modifiers.contains(.option) { flags.insert(.option) }
        if modifiers.contains(.shift) { flags.insert(.shift) }
        return KeyboardShortcut(KeyEquivalent(key), modifiers: flags)
    }
}
