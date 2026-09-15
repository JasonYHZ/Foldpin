import SwiftUI
import ServiceManagement

func readinessText(_ key: String) -> String {
    LanguageSettings.shared.bundle.localizedString(forKey: key, value: key, table: nil)
}

struct GeneralSettingsView: View {
    @ObservedObject var login: LoginItemSettings
    @ObservedObject private var language = LanguageSettings.shared
    let help: () -> Void
    let feedback: () -> Void
    var body: some View {
        Form {
            Section {
                Toggle(readinessText("Launch Foldpin at login"), isOn: Binding(get: { login.enabled }, set: { value in Task { await login.setEnabled(value) } })).disabled(login.changing)
                Text(readinessText("Restore your desktop notes quietly when you log in.")).foregroundStyle(.secondary)
                if login.status == .requiresApproval {
                    Text(readinessText("Waiting for approval in System Settings.")).foregroundStyle(.secondary)
                    Button(readinessText("Open Login Items Settings")) { SMAppService.openSystemSettingsLoginItems() }
                    Button(readinessText("Remove Login Registration")) { Task { await login.setEnabled(false) } }.disabled(login.changing)
                }
                if login.status == .notFound { Text(readinessText("The installed app could not be found. Move Foldpin to Applications and try again.")).foregroundStyle(.secondary) }
                if let error = login.error {
                    Text(error is LoginItemSettings.LoginError ? readinessText("Move Foldpin to Applications before enabling launch at login.") : error.localizedDescription).foregroundStyle(.red)
                    Button(readinessText("Retry")) { Task { await login.setEnabled(login.requestedEnabled) } }.disabled(login.changing)
                }
            }
            Section(readinessText("Help")) {
                Button(readinessText("User Guide"), action: help)
                Button(readinessText("Feedback…"), action: feedback)
            }
            Section("Foldpin") {
                LabeledContent(readinessText("Version"), value: FeedbackController.version)
                Text(readinessText("Floating notes for your Mac.")).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped).frame(width: 560, height: 460)
            .onAppear { login.refresh() }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in login.refresh() }
            .environment(\.locale, language.locale)
    }
}

@MainActor
final class FeedbackController {
    private var window: NSWindow?
    static var version: String {
        let info = Bundle.main.infoDictionary ?? [:]
        return "\(info["CFBundleShortVersionString"] as? String ?? "—") (\(info["CFBundleVersion"] as? String ?? "—"))"
    }
    static var diagnostics: String {
        #if arch(arm64)
        let architecture = "Apple silicon"
        #else
        let architecture = "Intel"
        #endif
        return "Foldpin \(version)\nmacOS \(ProcessInfo.processInfo.operatingSystemVersionString)\n\(architecture)"
    }
    func show() {
        if let window { NSApp.activate(); window.makeKeyAndOrderFront(nil); return }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 530, height: 470), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.title = "Foldpin"
        window.minSize = NSSize(width: 450, height: 400)
        window.contentView = NSHostingView(rootView: FeedbackView())
        window.center(); self.window = window; NSApp.activate(); window.makeKeyAndOrderFront(nil)
    }
}
struct FeedbackView: View {
    @ObservedObject private var language = LanguageSettings.shared
    @State private var message = ""
    @State private var copied = false
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(readinessText("Feedback Title")).font(.title.bold())
            Text(readinessText("Describe what happened and what you expected. Copy the template to share with the developer.")).foregroundStyle(.secondary)
            TextEditor(text: $message).onChange(of: message) { _, _ in copied = false }.font(.body).border(.quaternary).accessibilityLabel(readinessText("Your feedback"))
            Text(FeedbackController.diagnostics).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
            HStack {
                Text(readinessText("Only the text above will be copied.")).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(readinessText(copied ? "Copied" : "Copy Feedback")) {
                    let value = message + "\n\n" + FeedbackController.diagnostics
                    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(value, forType: .string); copied = true
                }
            }
        }.padding(24).environment(\.locale, language.locale)
    }
}
