import Foundation

/// Separates capture intent from device/window work, so permission and repeated
/// presses can be verified without opening the microphone or touching notes.
@MainActor
final class QuickRecordingFlow {
    private(set) var isStarting = false
    @discardableResult func trigger(canStart: Bool, finishCurrent: () -> Bool?,
        permission: @escaping @MainActor () async -> Bool,
        start: @escaping @MainActor () async -> Void,
        denied: @escaping @MainActor () -> Void,
        finished: @escaping @MainActor () -> Void = {}) -> Task<Void, Never>? {
        guard !isStarting else { return nil }
        if finishCurrent() != nil { return nil }
        guard canStart else { return nil }
        isStarting = true
        return Task { [self] in
            defer { isStarting = false; finished() }
            if await permission() { await start() }
            else { denied() }
        }
    }
}
