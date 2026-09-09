import AppKit
import AVFoundation
import Testing
@testable import FoldpinCore

private func audioFixture(_ directory: URL) throws -> (NoteFile, NoteAudio) {
    let file = NoteFile(url: directory.appendingPathComponent("note.json"))
    try FileManager.default.createDirectory(at: file.assetsURL, withIntermediateDirectories: true)
    let id = UUID(), url = file.assetsURL.appendingPathComponent(UUID().uuidString + ".wav")
    let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 8000, channels: 1))
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8000))
    buffer.frameLength = 8000
    for i in 0..<8000 { buffer.floatChannelData![0][i] = i < 4000 ? 0 : Float(sin(Double(i) * 0.1) * 0.5) }
    do { let writer = try AVAudioFile(forWriting: url, settings: format.settings); try writer.write(from: buffer) }
    let audio = try NoteAudioImporter.inspect(url: url, name: "会议 <语音>", id: id)
    try FileManager.default.moveItem(at: url, to: file.audioURL(audio))
    return (file, audio)
}

@Test func audioImportHasMeasuredWaveformAndKeepsSource() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let (file, audio) = try audioFixture(directory)
    #expect(audio.duration == 1 && audio.waveform.count == 128 && audio.isValid)
    #expect(audio.waveform.prefix(60).allSatisfy { $0 == 0 })
    #expect(audio.waveform.suffix(60).allSatisfy { $0 > 0 && $0 <= 0.501 })
    let before = try Data(contentsOf: file.audioURL(audio))
    let imported = try NoteAudioImporter.prepare(url: file.audioURL(audio), directory: file.assetsURL)
    #expect(imported.id != audio.id && imported.duration == audio.duration)
    #expect(try Data(contentsOf: file.audioURL(imported)) == before)
    #expect(try Data(contentsOf: file.audioURL(audio)) == before)
    let bad = directory.appendingPathComponent("bad.wav")
    try Data("not audio".utf8).write(to: bad)
    let assets = try FileManager.default.contentsOfDirectory(atPath: file.assetsURL.path).sorted()
    #expect(throws: (any Error).self) { try NoteAudioImporter.prepare(url: bad, directory: file.assetsURL) }
    #expect(try FileManager.default.contentsOfDirectory(atPath: file.assetsURL.path).sorted() == assets)
}

@Test func audioValidationAndMissingAssetProtectPreviousNote() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let (file, audio) = try audioFixture(directory)
    var document = NoteDocument(); document.content = NoteContent(blocks: [NoteBlock(kind: .audio, audio: audio)])
    try file.save(document)
    #expect(try file.load() == document)
    let bytes = try Data(contentsOf: file.url)
    try FileManager.default.removeItem(at: file.audioURL(audio))
    #expect(throws: NoteFileError.self) { try file.save(document) }
    #expect(try Data(contentsOf: file.url) == bytes)
    for invalid in [NoteAudio(name: "bad", fileExtension: "../wav", duration: 1),
                    NoteAudio(name: "bad", fileExtension: "wav", duration: -.infinity),
                    NoteAudio(name: "bad", fileExtension: "wav", duration: 0),
                    NoteAudio(name: "bad", fileExtension: "wav", duration: 1, waveform: [.nan])] {
        #expect(!invalid.isValid)
    }
    #expect(NoteAudio(name: "draft", fileExtension: "m4a", duration: 0, isDraft: true).isValid)
    #expect(throws: NoteFileError.self) { try NoteContent(blocks: [NoteBlock(kind: .paragraph, audio: audio)]).validate() }
    #expect(throws: NoteFileError.self) { try NoteContent(blocks: [NoteBlock(kind: .audio)]).validate() }
    let old = NoteContent(blocks: [NoteBlock(text: "old note")])
    #expect(try JSONDecoder().decode(NoteContent.self, from: JSONEncoder().encode(old)) == old)
}

@MainActor private final class AudioUndoDelegate: NSObject, NSTextViewDelegate {
    let history = UndoManager()
    func undoManager(for view: NSTextView) -> UndoManager? { history }
}
@MainActor private func audioEditor(_ content: NoteContent, file: NoteFile) -> PaperTextView {
    _ = NSApplication.shared
    let editor = PaperTextView(usingTextLayoutManager: true)
    editor.file = file; editor.frame = NSRect(x: 0, y: 0, width: 360, height: 300)
    editor.textContainer?.size = NSSize(width: 296, height: CGFloat.greatestFiniteMagnitude)
    editor.textContainer?.lineFragmentPadding = 0
    editor.isRichText = true; editor.configure(content: content)
    return editor
}

@Test @MainActor func audioAttachmentRoundTripAndNativeUndoRetainAsset() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let (file, audio) = try audioFixture(directory)
    let block = NoteBlock(kind: .audio, audio: audio)
    let content = NoteContent(blocks: [NoteBlock(text: "前文"), block, NoteBlock(text: "后文")])
    let editor = audioEditor(content, file: file)
    let delegate = AudioUndoDelegate(); delegate.history.groupsByEvent = false
    editor.delegate = delegate; editor.allowsUndo = true
    #expect(BlockTextCodec.read(editor.attributedString(), typing: editor.typingAttributes).map(\.block) == content.blocks)
    var attachment: AudioTextAttachment?
    editor.attributedString().enumerateAttribute(.attachment, in: NSRange(location: 0, length: editor.attributedString().length)) { value, _, _ in
        if let value = value as? AudioTextAttachment { attachment = value }
    }
    let actual = try #require(attachment)
    #expect(actual.model?.audio == audio && actual.bounds.height == 64 && !actual.usesTextAttachmentView)
    #expect(actual.model?.makePlayerView() != nil)
    let selection = NSRange(location: 1, length: 0); editor.setSelectedRange(selection)
    var renamed = audio; renamed.name = "新名字"
    delegate.history.beginUndoGrouping()
    #expect(editor.updateAudio(renamed, blockID: block.id))
    delegate.history.endUndoGrouping()
    #expect(editor.selectedRange() == selection && editor.content.blocks[1].audio == renamed)
    delegate.history.undo(); #expect(editor.content == content)
    for action in [BlockAction.duplicate, .moveUp, .delete] {
        delegate.history.beginUndoGrouping(); #expect(editor.performBlockAction(action, blockID: block.id)); delegate.history.endUndoGrouping()
        #expect(FileManager.default.fileExists(atPath: file.audioURL(audio).path))
        delegate.history.undo(); #expect(editor.content == content)
    }
    editor.isEditable = false
    #expect(!editor.updateAudio(renamed, blockID: block.id))
}

@Test @MainActor func audioClipboardEmbedsBytesAndFailsBeforeReplacingClipboard() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let (file, audio) = try audioFixture(directory)
    let content = NoteContent(blocks: [NoteBlock(kind: .audio, audio: audio), NoteBlock(text: "正文")])
    let board = NSPasteboard(name: .init("Foldpin-audio-test-\(UUID())")); defer { board.releaseGlobally() }
    try NoteClipboard.copy(content, file: file, to: board)
    #expect(board.string(forType: .string) == content.plainText)
    let html = try #require(board.string(forType: .html))
    #expect(html.contains("data:audio/wav;base64,") && html.contains("&lt;语音&gt;") && !html.contains(directory.path))
    let rich = try NSAttributedString(data: #require(board.data(forType: .rtfd)), options: [.documentType: NSAttributedString.DocumentType.rtfd], documentAttributes: nil)
    let embedded = (rich.attribute(.attachment, at: 0, effectiveRange: nil) as? NSTextAttachment)?.fileWrapper?.regularFileContents
    #expect(try embedded == Data(contentsOf: file.audioURL(audio)))
    try FileManager.default.removeItem(at: file.audioURL(audio))
    #expect(throws: (any Error).self) { try NoteClipboard.copy(content, file: file, to: board) }
    #expect(board.string(forType: .string) == content.plainText)
    let editor = audioEditor(NoteContent(), file: file)
    #expect(!editor.insertPastedBlocks(content))
}

@Test @MainActor func audioSurvivesNoteDeleteRestoreAndDraftFinalization() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let (file, audio) = try audioFixture(directory)
    let library = NoteLibrary(directory: directory)
    let entry = try #require(library.entries.first)
    // Library and fixture use the same root assets directory.
    var draft = audio; draft.isDraft = true; draft.duration = 0; draft.waveform = []
    let block = NoteBlock(kind: .audio, audio: draft)
    let editor = audioEditor(NoteContent(blocks: [block]), file: file)
    editor.onContentChange = { entry.store.edit($0) }
    editor.onAudioCommit = { entry.store.flush() }
    let model = try #require((editor.attributedString().attribute(.attachment, at: 0, effectiveRange: nil) as? AudioTextAttachment)?.model)
    #expect(model.finish())
    #expect(!model.audio.isDraft)
    #expect(editor.content.blocks[0].audio?.isDraft == false && editor.content.blocks[0].audio?.duration == 1)
    #expect(library.deleteNote(entry.id))
    let reopened = NoteLibrary(directory: directory)
    let restored = try #require(reopened.restoreNote(entry.id))
    #expect(restored.store.document.content == editor.content)
    #expect(FileManager.default.fileExists(atPath: file.audioURL(audio).path))
    model.seek(2); #expect(model.position == 1)
    model.seek(-1); #expect(model.position == 0)
    model.stop()
}

@Test @MainActor func audioPlayerRendersAtNarrowAndRegularWidths() throws {
    let output = ProcessInfo.processInfo.environment["FOLDPIN_AUDIO_PREVIEW_DIRECTORY"]
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let (file, audio) = try audioFixture(directory)
    let editor = audioEditor(NoteContent(blocks: [NoteBlock(kind: .audio, audio: audio)]), file: file)
    editor.updateColors(NotePalette.paperText)
    let model = AudioBlockModel(blockID: editor.content.blocks[0].id, audio: audio, file: file, editor: editor)
    for (index, width) in [CGFloat(336), 210, 336].enumerated() {
        if index == 2 { model.audio.isDraft = true; model.isRecording = true; model.livePeaks = audio.waveform; model.position = 12 }
        let view = model.makePlayerView()
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: width + 32, height: 96), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.appearance = NSAppearance(named: .aqua)
        let root = NSView(frame: NSRect(x: 0, y: 0, width: width + 32, height: 96))
        root.wantsLayer = true; root.layer?.backgroundColor = NSColor(calibratedRed: 0.985, green: 0.943, blue: 0.753, alpha: 1).cgColor
        window.contentView = root
        view.frame = NSRect(x: 16, y: 16, width: width, height: 64); root.addSubview(view)
        root.layoutSubtreeIfNeeded(); root.displayIfNeeded()
        let bitmap = try #require(root.bitmapImageRepForCachingDisplay(in: root.bounds))
        root.cacheDisplay(in: root.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        if let output {
            try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
            try png.write(to: URL(fileURLWithPath: output).appendingPathComponent("audio-\(index).png"))
        }
        #expect(view.bounds.width == width && view.bounds.height == 64)
        window.close()
    }
    model.stop()
}

@Test @MainActor func audioFinalizationFailureRetainsFileAndNativeHistory() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let (file, audio) = try audioFixture(directory)
    var draft = audio; draft.isDraft = true; draft.duration = 0
    let content = NoteContent(blocks: [NoteBlock(kind: .audio, audio: draft)])
    let editor = audioEditor(content, file: file)
    let model = try #require((editor.attributedString().attribute(.attachment, at: 0, effectiveRange: nil) as? AudioTextAttachment)?.model)
    editor.onAudioCommit = { false }
    #expect(!model.finish() && model.error != nil)
    #expect(FileManager.default.fileExists(atPath: file.audioURL(audio).path))
    #expect(editor.content.blocks[0].audio?.duration == 1)
    editor.configure(content: content)
    editor.isEditable = false
    #expect(!model.finish())
    #expect(editor.content == content)
}

@Test @MainActor func audioPlayerAppearsWithinNativeEditor() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let (file, audio) = try audioFixture(directory)
    let editor = audioEditor(NoteContent(blocks: [NoteBlock(text: "Before"), NoteBlock(kind: .audio, audio: audio), NoteBlock(text: "After")]), file: file)
    let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 360, height: 300), styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 360, height: 300))
    scroll.documentView = editor; window.contentView = scroll
    defer { window.close() }
    let manager = try #require(editor.textLayoutManager)
    manager.ensureLayout(for: try #require(manager.textContentManager).documentRange)
    scroll.layoutSubtreeIfNeeded()
    manager.textViewportLayoutController.layoutViewport()
    scroll.displayIfNeeded()
    editor.synchronizeAudioViews()
    func hostingCount(_ view: NSView) -> Int {
        return (String(describing: type(of: view)).contains("NSHostingView") ? 1 : 0) + view.subviews.reduce(0) { $0 + hostingCount($1) }
    }
    #expect(hostingCount(editor) == 1)
    #expect(editor.content.blocks.map(\.kind) == [.paragraph, .audio, .paragraph])
    window.close()
}
