import AppKit

/// Captures only while this focused control is explicitly recording. Global
/// hot-key events are forwarded here too, without unregistering working keys.
@MainActor
final class ShortcutRecorder: NSButton {
    var onCapture: ((ShortcutBinding) -> Void)?
    var onClear: (() -> Void)?
    var binding = ShortcutBinding.disabled { didSet { refreshTitle() } }
    var recording = false
    private var monitor: Any?
    private var resignObserver: NSObjectProtocol?
    private var previousFocus: NSResponder?
    override var acceptsFirstResponder: Bool { true }
    init() {
        super.init(frame: .zero)
        bezelStyle = .rounded; setButtonType(.momentaryPushIn)
        target = self; action = #selector(beginRecording)
        refreshTitle()
    }
    required init?(coder: NSCoder) { nil }
    func refreshTitle() {
        let bundle = LanguageSettings.shared.bundle
        title = recording ? String(localized: "Press shortcut…", bundle: bundle)
            : binding.code == nil ? String(localized: "Not set", bundle: bundle) : binding.keycaps.joined()
        toolTip = String(localized: "Click and press a shortcut. Escape cancels; Delete clears.", bundle: bundle)
    }
    @objc func beginRecording() {
        guard !recording, ShortcutSettings.shared.recordingHandler == nil, let window else { return }
        previousFocus = window.firstResponder
        window.makeFirstResponder(self)
        recording = true; refreshTitle()
        ShortcutSettings.shared.recordingHandler = { [weak self] value in self?.accept(value) }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self, self.recording else { return event }
            if event.type != .keyDown {
                if event.window !== self.window || !self.bounds.contains(self.convert(event.locationInWindow, from: nil)) { self.endRecording() }
                return event
            }
            guard event.window === self.window else { self.endRecording(); return event }
            self.capture(event); return nil
        }
        resignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.endRecording() }
        }
    }
    private func capture(_ event: NSEvent) {
        guard !event.isARepeat else { return }
        let modifiers = event.modifierFlags.intersection(ShortcutBinding.allowedModifiers)
        if modifiers.isEmpty {
            if event.keyCode == 53 { endRecording(); return }
            if event.keyCode == 48 { endRecording(); window?.selectNextKeyView(self); return }
            if event.keyCode == 51 || event.keyCode == 117 { endRecording(); onClear?(); return }
        }
        accept(ShortcutBinding(code: event.keyCode, modifiers: modifiers))
    }
    private func accept(_ value: ShortcutBinding) {
        guard recording else { return }
        endRecording(); onCapture?(value)
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard recording else { return super.performKeyEquivalent(with: event) }
        capture(event); return true
    }
    override func resignFirstResponder() -> Bool { endRecording(restoreFocus: false); return super.resignFirstResponder() }
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if window !== newWindow { endRecording(restoreFocus: false) }
        super.viewWillMove(toWindow: newWindow)
    }
    func endRecording(restoreFocus: Bool = true) {
        guard recording else { return }
        recording = false
        ShortcutSettings.shared.recordingHandler = nil
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver); self.resignObserver = nil }
        refreshTitle()
        let previous = previousFocus; previousFocus = nil
        if restoreFocus, window?.firstResponder === self, previous !== self { window?.makeFirstResponder(previous) }
    }
    isolated deinit {
        if recording { ShortcutSettings.shared.recordingHandler = nil }
        if let monitor { NSEvent.removeMonitor(monitor) }
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
    }
}
