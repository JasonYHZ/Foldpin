import Carbon
import CoreGraphics

/// Registers new combinations before releasing old ones. Failed changes leave
/// all previous registrations intact, including a page-wide reset or a swap.
@MainActor
final class GlobalShortcut {
    private struct Registration { let id: UInt32; let reference: EventHotKeyRef }
    private var registrations: [ShortcutBinding: Registration] = [:]
    private var actions: [UInt32: GlobalShortcutAction] = [:]
    private var pressed: Set<UInt32> = []
    private var handler: EventHandlerRef?
    private var nextID: UInt32 = 1
    var onPress: (GlobalShortcutAction) -> Void = { _ in }
    var capture: ((ShortcutBinding) -> Bool)?

    private let installsHandler: Bool
    var registerKey: (ShortcutBinding, UInt32) -> (OSStatus, EventHotKeyRef?) = { binding, id in
        var reference: EventHotKeyRef?
        let status = RegisterEventHotKey(UInt32(binding.code!), binding.carbonModifiers,
            EventHotKeyID(signature: 0x464F4C44, id: id), GetApplicationEventTarget(), 0, &reference)
        return (status, reference)
    }
    var unregisterKey: (EventHotKeyRef) -> Void = { UnregisterEventHotKey($0) }
    var keyIsDown: (UInt16) -> Bool = { CGEventSource.keyState(.combinedSessionState, key: $0) }
    init(installsHandler: Bool = true) { self.installsHandler = installsHandler }
    func receive(id: UInt32, isPressed: Bool) {
        if !isPressed { pressed.remove(id); return }
        guard pressed.insert(id).inserted, let action = actions[id],
              let binding = registrations.first(where: { $0.value.id == id })?.key else { return }
        if capture?(binding) != true { onPress(action) }
    }

    func register(_ bindings: [GlobalShortcutAction: ShortcutBinding]) -> OSStatus {
        let enabled = bindings.values.filter { $0.code != nil }
        guard Set(enabled).count == enabled.count, bindings.values.allSatisfy(\.isValid) else { return OSStatus(paramErr) }
        if handler == nil && installsHandler {
            var types = [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
                         EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))]
            let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
                guard let event, let context else { return OSStatus(eventNotHandledErr) }
                var identifier = EventHotKeyID()
                guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                                        MemoryLayout<EventHotKeyID>.size, nil, &identifier) == noErr,
                      identifier.signature == 0x464F4C44 else { return OSStatus(eventNotHandledErr) }
                MainActor.assumeIsolated {
                    let owner = Unmanaged<GlobalShortcut>.fromOpaque(context).takeUnretainedValue()
                    owner.receive(id: identifier.id, isPressed: GetEventKind(event) != UInt32(kEventHotKeyReleased))
                }
                return noErr
            }, types.count, &types, Unmanaged.passUnretained(self).toOpaque(), &handler)
            guard status == noErr else { return status }
        }
        let required = Set(bindings.values.filter { $0.code != nil })
        var added: [ShortcutBinding: Registration] = [:]
        for binding in required where registrations[binding] == nil {
            guard binding.isValid, binding.code != nil else { return OSStatus(paramErr) }
            let id = nextID; nextID &+= 1
            let (status, reference) = registerKey(binding, id)
            guard status == noErr, let reference else {
                for value in added.values { unregisterKey(value.reference) }
                return status == noErr ? OSStatus(paramErr) : status
            }
            added[binding] = Registration(id: id, reference: reference)
        }
        for binding in Array(registrations.keys) where !required.contains(binding) {
            if let value = registrations.removeValue(forKey: binding) { unregisterKey(value.reference); pressed.remove(value.id) }
        }
        registrations.merge(added) { _, new in new }
        for (binding, value) in added where binding.code.map(keyIsDown) == true { pressed.insert(value.id) }
        actions = Dictionary(uniqueKeysWithValues: bindings.compactMap { action, binding in registrations[binding].map { ($0.id, action) } })
        return noErr
    }
    func stop() {
        for value in registrations.values { unregisterKey(value.reference) }
        registrations.removeAll(); actions.removeAll(); pressed.removeAll()
        if let handler { RemoveEventHandler(handler) }
        handler = nil
    }
    isolated deinit { stop() }
}
