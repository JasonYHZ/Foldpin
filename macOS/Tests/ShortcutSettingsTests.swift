import AppKit
import Testing
import SwiftUI
import Carbon
@testable import FoldpinCore

@MainActor private func shortcutFixture() -> (ShortcutSettings, UserDefaults, String) {
    let name = "Foldpin-shortcut-tests-" + UUID().uuidString
    let defaults = UserDefaults(suiteName: name)!
    let settings = ShortcutSettings(defaults: defaults)
    settings.systemConflict = { _ in false }
    return (settings, defaults, name)
}

@Test @MainActor func shortcutsPreserveLegacyAndPersistClearResetAndRebinding() throws {
    let (settings, defaults, name) = shortcutFixture()
    defer { defaults.removePersistentDomain(forName: name) }
    #expect(settings.binding(GlobalShortcutAction.toggleNotes) == .named(" ", [.control,.option]))
    #expect(settings.binding(GlobalShortcutAction.newNote) == .named("n", [.control,.option]))
    #expect(settings.binding(GlobalShortcutAction.quickRecord) == .named("r", [.control,.option]))
    #expect(settings.binding(GlobalShortcutAction.shelf) == .named("o", [.control,.option]))
    #expect(settings.binding(NoteAction.actions) == .named("k", .command))
    let changed = ShortcutBinding.named("j", [.control,.option])
    #expect(settings.set(changed, for: "note.actions"))
    let reopened = ShortcutSettings(defaults: defaults); reopened.systemConflict = { _ in false }
    #expect(reopened.binding(NoteAction.actions) == changed)
    #expect(reopened.set(.disabled, for: "note.actions"))
    #expect(ShortcutSettings(defaults: defaults).binding(NoteAction.actions).code == nil)
    #expect(reopened.reset(["note.actions"]))
    #expect(reopened.binding(NoteAction.actions) == .named("k",.command))
    defaults.removeObject(forKey: "globalShortcutDefaults.v1")
    defaults.set(1, forKey: "captureShortcut")
    let legacy = ShortcutSettings(defaults: defaults)
    #expect(legacy.binding(GlobalShortcutAction.toggleNotes) == .named("n",[.control,.option]))
    #expect(legacy.binding(GlobalShortcutAction.newNote) == .disabled)
    legacy.systemConflict = { _ in false }
    #expect(legacy.reset(GlobalShortcutAction.allCases.map(\.id)))
    #expect(ShortcutSettings(defaults: defaults).binding(GlobalShortcutAction.toggleNotes) == .named(" ",[.control,.option]))
    #expect(legacy.set(.disabled, for: GlobalShortcutAction.quickRecord.id))
    #expect(ShortcutSettings(defaults: defaults).binding(GlobalShortcutAction.quickRecord) == .disabled)
    // A previous local customization wins over a newly introduced global default.
    defaults.removeObject(forKey: "globalShortcutDefaults.v1")
    defaults.set(0, forKey: "captureShortcut")
    defaults.set(try JSONEncoder().encode(["note.actions": ShortcutBinding.named("o", [.control,.option])]), forKey: ShortcutSettings.preferenceKey)
    let migrated = ShortcutSettings(defaults: defaults)
    #expect(migrated.binding(GlobalShortcutAction.shelf) == .disabled)
    #expect(migrated.binding(NoteAction.actions) == .named("o", [.control,.option]))
}

@Test @MainActor func shortcutConflictsAndRegistrationFailuresKeepPreviousBindings() {
    let (settings, defaults, name) = shortcutFixture()
    defer { defaults.removePersistentDomain(forName: name) }
    var registrations = 0
    settings.applyGlobals = { _ in registrations += 1; return 0 }
    #expect(!settings.set(.named("k",.command), for: GlobalShortcutAction.newNote.id))
    #expect(!settings.set(.named("v",.command), for: "note.actions"))
    #expect(!settings.set(.named("r",.shift), for: GlobalShortcutAction.quickRecord.id))
    #expect(registrations == 0 && settings.overrides.isEmpty)
    let chord = ShortcutBinding.named("u",[.control,.option])
    settings.systemConflict = { $0 == chord }
    #expect(!settings.set(chord, for: GlobalShortcutAction.quickRecord.id))
    settings.systemConflict = { _ in false }
    #expect(settings.set(chord, for: GlobalShortcutAction.quickRecord.id))
    let saved = defaults.data(forKey: ShortcutSettings.preferenceKey)
    let previous = settings.overrides
    settings.applyGlobals = { _ in -9878 }
    #expect(!settings.set(.named("t",[.control,.option]), for: GlobalShortcutAction.quickRecord.id))
    #expect(settings.overrides == previous && defaults.data(forKey: ShortcutSettings.preferenceKey) == saved)
    #expect(settings.error != nil)
    #expect(!settings.reset(GlobalShortcutAction.allCases.map(\.id)))
    #expect(settings.overrides == previous)
}

@Test @MainActor func shortcutPageResetChecksCrossScopeConflictsAndCaptureSuppressesRouting() throws {
    let (settings, defaults, name) = shortcutFixture()
    defer { defaults.removePersistentDomain(forName: name) }
    #expect(settings.set(.disabled, for: "note.actions"))
    #expect(settings.set(.named("k",.command), for: GlobalShortcutAction.newNote.id))
    #expect(!settings.reset(ShortcutSettings.localIDs))
    #expect(settings.binding(NoteAction.actions).code == nil)
    #expect(settings.set(.disabled, for: GlobalShortcutAction.newNote.id))
    #expect(settings.reset(ShortcutSettings.localIDs))
    let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command,.capsLock],
        timestamp: 0, windowNumber: 0, context: nil, characters: "K", charactersIgnoringModifiers: "k", isARepeat: false, keyCode: 40))
    #expect(settings.matchingNote(event) == .actions)
    settings.recordingHandler = { _ in }
    #expect(settings.matchingNote(event) == nil && settings.matchingEditor(event) == nil)
    settings.recordingHandler = nil
    #expect(settings.set(.named("j",[.command,.control]), for: "note.actions"))
    #expect(settings.matchingNote(event) == nil)
}

@Test func shortcutBindingValidationAndHintsRespectModifiers() {
    let value = ShortcutBinding(code: 126, modifiers: [.command,.option,.capsLock])
    #expect(value.keycaps == ["⌥","⌘","↑"] && value.isValid)
    #expect(ShortcutBinding.disabled.isValid && ShortcutBinding.disabled.keycaps.isEmpty)
    #expect(!ShortcutBinding(code: 53, modifiers: .command).isValid)
    #expect(!ShortcutBinding.named("a",.option).isValid)
    #expect(!ShortcutBinding(code: nil, modifiers: .command).isValid)
}

@Test @MainActor func quickRecordingWaitsForPermissionAndDoesNotDuplicateOnRepeatOrSaveFailure() async throws {
    let flow = QuickRecordingFlow()
    var permissionRequests = 0, starts = 0, denials = 0, finished = 0
    var grant: CheckedContinuation<Bool, Never>?
    let firstRequest = flow.trigger(canStart: true, finishCurrent: { nil }, permission: {
        permissionRequests += 1
        return await withCheckedContinuation { grant = $0 }
    }, start: { starts += 1 }, denied: { denials += 1 }, finished: { finished += 1 })
    let first = try #require(firstRequest)
    while grant == nil { await Task.yield() }
    #expect(flow.isStarting && starts == 0)
    let repeated = flow.trigger(canStart: true, finishCurrent: { nil }, permission: { true }, start: { starts += 1 }, denied: {})
    #expect(repeated == nil)
    grant?.resume(returning: false)
    await first.value
    #expect(permissionRequests == 1 && starts == 0 && denials == 1 && finished == 1 && !flow.isStarting)
    let secondRequest = flow.trigger(canStart: true, finishCurrent: { nil }, permission: { true }, start: { starts += 1 }, denied: {})
    let second = try #require(secondRequest)
    await second.value
    #expect(starts == 1)
    let failedSave = flow.trigger(canStart: true, finishCurrent: { false }, permission: { true }, start: { starts += 1 }, denied: {})
    #expect(failedSave == nil && starts == 1)
    let complete = flow.trigger(canStart: false, finishCurrent: { true }, permission: { true }, start: { starts += 1 }, denied: {})
    #expect(complete == nil)
}

@MainActor private final class ShortcutUndoDelegate: NSObject, NSTextViewDelegate {
    let history = UndoManager()
    func undoManager(for view: NSTextView) -> UndoManager? { history }
}

@Test @MainActor func shortcutEditorRebindingKeepsNativeSelectionAndUndo() throws {
    _ = NSApplication.shared
    let (settings, defaults, name) = shortcutFixture()
    defer { defaults.removePersistentDomain(forName: name) }
    let editor = PaperTextView(usingTextLayoutManager: true)
    editor.shortcuts = settings
    let content = NoteContent(blocks: [NoteBlock(text: "first"), NoteBlock(text: "second")])
    editor.configure(content: content)
    let delegate = ShortcutUndoDelegate(); delegate.history.groupsByEvent = false
    editor.delegate = delegate; editor.allowsUndo = true
    editor.setSelectedRange(NSRange(location: 1, length: 0))
    #expect(settings.set(.named("j",[.control,.option]), for: EditorShortcutAction.duplicateBlock.id))
    #expect(editor.content == content && editor.selectedRange().location == 1 && !delegate.history.canUndo)
    let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.control,.option],
        timestamp: 0, windowNumber: 0, context: nil, characters: "j", charactersIgnoringModifiers: "j", isARepeat: false, keyCode: 38))
    delegate.history.beginUndoGrouping(); #expect(editor.performKeyEquivalent(with: event)); delegate.history.endUndoGrouping()
    #expect(editor.content.blocks.count == 3 && editor.content.blocks[1].text == "first")
    delegate.history.undo(); #expect(editor.content == content)
    let old = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
        timestamp: 0, windowNumber: 0, context: nil, characters: "d", charactersIgnoringModifiers: "d", isARepeat: false, keyCode: 2))
    #expect(settings.matchingEditor(old) == nil)
    editor.isEditable = false
    #expect(!editor.performEditorShortcut(.duplicateBlock))
}

@Test @MainActor func shortcutSettingsNativeLayoutsAndRecorderCancellation() async throws {
    _ = NSApplication.shared
    let (settings, defaults, name) = shortcutFixture()
    defer { defaults.removePersistentDomain(forName: name) }
    let directory = URL(fileURLWithPath: "/private/tmp/Foldpin-ShortcutPreview")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    for global in [false,true] {
        let host = NSHostingView(rootView: ShortcutSettingsView(settings: settings, global: global))
        host.sizingOptions = []
        host.frame = NSRect(x: 0, y: 0, width: 556, height: 720)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.appearance = NSAppearance(named: .aqua)
        let root = NSView(frame: host.frame)
        root.wantsLayer = true; root.layer?.backgroundColor = NSColor.white.cgColor
        window.contentView = root; root.addSubview(host)
        host.frame = root.bounds
        try await Task.sleep(for: .milliseconds(120))
        root.layoutSubtreeIfNeeded(); host.display(); root.displayIfNeeded()
        let bitmap = try #require(root.bitmapImageRepForCachingDisplay(in: root.bounds))
        root.cacheDisplay(in: root.bounds, to: bitmap)
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent(global ? "global.png" : "local.png"))
        window.close()
    }
    let recorder = ShortcutRecorder()
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 70), styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.contentView = recorder
    defer { recorder.endRecording(); window.close() }
    var captured: ShortcutBinding?
    recorder.onCapture = { captured = $0 }
    recorder.beginRecording()
    #expect(recorder.recording && ShortcutSettings.shared.recordingHandler != nil)
    ShortcutSettings.shared.recordingHandler?(.named("r", [.control,.option]))
    #expect(captured == .named("r", [.control,.option]) && !recorder.recording)
    recorder.beginRecording()
    let escape = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
        windowNumber: window.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
    #expect(recorder.performKeyEquivalent(with: escape))
    #expect(!recorder.recording && ShortcutSettings.shared.recordingHandler == nil)
}

@Test @MainActor func shortcutGlobalRegistrationIsTransactionalAndSuppressesRepeatAndCapture() {
    let registry = GlobalShortcut(installsHandler: false)
    var removed: [EventHotKeyRef] = [], received: [GlobalShortcutAction] = []
    registry.registerKey = { _, id in (0, OpaquePointer(bitPattern: Int(id))) }
    registry.unregisterKey = { removed.append($0) }
    registry.keyIsDown = { _ in false }
    registry.onPress = { received.append($0) }
    let first = ShortcutBinding.named("r", [.control,.option])
    #expect(registry.register([.quickRecord:first]) == 0)
    registry.receive(id: 1, isPressed: true); registry.receive(id: 1, isPressed: true)
    #expect(received == [.quickRecord])
    registry.receive(id: 1, isPressed: false)
    registry.capture = { $0 == first }
    registry.receive(id: 1, isPressed: true)
    #expect(received == [.quickRecord])
    registry.receive(id: 1, isPressed: false); registry.capture = nil
    registry.registerKey = { _, _ in (-9878,nil) }
    #expect(registry.register([.quickRecord:.named("t",[.control,.option])]) == -9878)
    #expect(removed.isEmpty)
    registry.receive(id: 1, isPressed: true)
    #expect(received == [.quickRecord,.quickRecord])
    registry.receive(id: 1, isPressed: false)
    // Reusing a registered combination for another action requires no release.
    #expect(registry.register([.newNote:first]) == 0)
    registry.receive(id: 1, isPressed: true)
    #expect(received.last == .newNote && removed.isEmpty)
    registry.stop(); #expect(removed.count == 1)
}
