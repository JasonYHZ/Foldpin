import AppKit
import Combine
import ServiceManagement
import CoreServices

@MainActor
final class LoginItemSettings: ObservableObject {
    @Published private(set) var status: SMAppService.Status
    @Published private(set) var error: Error?
    @Published private(set) var changing = false
    private(set) var requestedEnabled = true
    private let readStatus: () -> SMAppService.Status
    private let register: () throws -> Void
    private let unregister: () async throws -> Void
    private let installed: () -> Bool
    init(readStatus: @escaping () -> SMAppService.Status = { SMAppService.mainApp.status },
         register: @escaping () throws -> Void = { try SMAppService.mainApp.register() },
         unregister: @escaping () async throws -> Void = { try await SMAppService.mainApp.unregister() },
         installed: @escaping () -> Bool = {
             let app = Bundle.main.bundleURL.standardizedFileURL.resolvingSymlinksInPath()
             return FileManager.default.urls(for: .applicationDirectory, in: [.localDomainMask, .userDomainMask])
                 .contains { app.path.hasPrefix($0.path + "/") }
         }) {
        self.readStatus = readStatus; self.register = register; self.unregister = unregister; self.installed = installed
        status = readStatus()
    }
    var enabled: Bool { status == .enabled }
    func refresh() { status = readStatus() }
    func setEnabled(_ value: Bool) async {
        guard !changing else { return }
        changing = true; error = nil; requestedEnabled = value
        defer { refresh(); changing = false }
        do {
            if value {
                guard installed() else { throw LoginError.installFirst }
                // Approval is granted in System Settings, never by reregistering.
                if readStatus() == .requiresApproval { SMAppService.openSystemSettingsLoginItems(); return }
                try register()
            } else { try await unregister() }
        } catch { self.error = error }
    }
    nonisolated enum LoginError: LocalizedError {
        case installFirst
        var errorDescription: String? { "Move Foldpin to Applications before enabling launch at login." }
    }
    static var isBackgroundLaunch: Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent, event.eventID == kAEOpenApplication else { return false }
        let reason = event.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue
        return reason == keyAELaunchedAsLogInItem || reason == keyAELaunchedAsServiceItem
    }
}
