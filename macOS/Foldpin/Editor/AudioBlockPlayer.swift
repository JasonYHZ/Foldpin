import AppKit
import AVFoundation
import Combine
import SwiftUI

@MainActor
final class AudioBlockModel: ObservableObject {
    static weak var playing: AudioBlockModel?
    static weak var recording: AudioBlockModel?
    static var requestingRecording = false
    let blockID: UUID
    weak var editor: PaperTextView?
    let file: NoteFile
    @Published var audio: NoteAudio
    @Published var position: Double = 0
    @Published var isPlaying = false
    @Published var isRecording = false
    @Published var isPaused = false
    @Published var rate: Float = 1
    @Published var error: String?
    @Published var livePeaks: [Float] = []
    var errorMessage: String? { error.map { bundle.localizedString(forKey: $0, value: nil, table: nil) } }
    private var player: AVAudioPlayer?
    private var recorder: AVAudioRecorder?
    private var timer: Timer?
    private var metered: [(Double, Float)] = []
    var bundle: Bundle { LanguageSettings.shared.bundle }
    var ink: Color { Color(nsColor: editor?.noteColor ?? .labelColor) }

    init(blockID: UUID, audio: NoteAudio, file: NoteFile, editor: PaperTextView?) {
        self.blockID = blockID; self.audio = audio; self.file = file; self.editor = editor
    }
    func update(_ value: NoteAudio) {
        if audio.id != value.id { stop(); player = nil; position = 0 }
        if audio != value { audio = value }
    }
    func start(_ recorder: AVAudioRecorder) {
        VideoBlockModel.playing?.pause()
        Self.playing?.pause()
        self.recorder = recorder
        recorder.isMeteringEnabled = true
        guard recorder.record() else { error = "Could not start recording. Your draft is kept."; self.recorder = nil; return }
        Self.recording = self
        isRecording = true; isPaused = false; error = nil
        startTimer()
    }
    func toggleRecordingPause() {
        guard let recorder else { return }
        if isPaused {
            guard recorder.record() else { error = "Could not resume recording. Finish to keep your audio."; return }
        } else { recorder.pause() }
        isPaused.toggle()
    }
    @discardableResult func finish() -> Bool {
        guard audio.isDraft else { return true }
        recorder?.stop(); recorder = nil
        if Self.recording === self { Self.recording = nil }
        isRecording = false; isPaused = false; stopTimer()
        do {
            let recorded = try AVAudioFile(forReading: file.audioURL(audio))
            let duration = Double(recorded.length) / recorded.processingFormat.sampleRate
            guard duration.isFinite, duration > 0 else { throw CocoaError(.fileReadCorruptFile) }
            var value = audio
            value.duration = duration; value.isDraft = false
            var peaks = [Float](repeating: 0, count: 128)
            for (time, peak) in metered { let index = min(127, Int(time / duration * 128)); peaks[index] = max(peaks[index], peak) }
            value.waveform = metered.isEmpty ? [] : peaks
            guard editor?.updateAudio(value, blockID: blockID) == true else {
                error = "Audio could not be saved. Your recording file is kept; retry saving."
                return false
            }
            error = nil; position = 0
            return true
        } catch {
            self.error = "Could not read this recording. The original file is kept."
            return false
        }
    }
    func togglePlayback() {
        guard file.libraryPath?.writable != false else { return }
        if isPlaying { pause(); return }
        guard !audio.isDraft, Self.recording == nil else { return }
        VideoBlockModel.playing?.pause()
        Self.playing?.pause()
        do {
            if player == nil { player = try AVAudioPlayer(contentsOf: file.audioURL(audio)); player?.enableRate = true }
            guard let player else { return }
            player.rate = rate
            player.currentTime = position >= player.duration - 0.05 ? 0 : position
            guard player.play() else { throw CocoaError(.fileReadCorruptFile) }
            Self.playing = self; isPlaying = true; error = nil
            startTimer()
        } catch { self.error = "Could not play audio. Check that the file is available." }
    }
    func pause() { player?.pause(); isPlaying = false; stopTimer(); if Self.playing === self { Self.playing = nil } }
    func releaseForLibraryChange() { pause(); player = nil }
    func seek(_ fraction: Double) {
        guard !audio.isDraft else { return }
        position = min(audio.duration, max(0, fraction * audio.duration))
        player?.currentTime = position
    }
    func setRate(_ value: Float) { rate = value; player?.rate = value }
    func makePlayerView() -> NSView { NSHostingView(rootView: AudioBlockPlayer(model: self)) }
    func stop() {
        pause(); recorder?.stop(); recorder = nil; isRecording = false; isPaused = false
        if Self.recording === self { Self.recording = nil }
    }
    private func startTimer() {
        stopTimer()
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        self.timer = timer; RunLoop.main.add(timer, forMode: .common)
    }
    private func stopTimer() { timer?.invalidate(); timer = nil }
    private func tick() {
        if let recorder {
            position = recorder.currentTime
            if !isPaused {
                recorder.updateMeters()
                let level = Float(pow(10, Double(recorder.peakPower(forChannel: 0)) / 20))
                let peak = min(1, max(0, level.isFinite ? level : 0))
                livePeaks.append(peak); if livePeaks.count > 64 { livePeaks.removeFirst() }
                metered.append((position, peak))
                if metered.count > 2048 { metered = stride(from: 0, to: metered.count - 1, by: 2).map { (metered[$0].0, max(metered[$0].1, metered[$0 + 1].1)) } }
                if !recorder.isRecording { _ = finish() }
            }
        } else if let player {
            position = player.currentTime
            if !player.isPlaying { position = player.duration; pause() }
        }
    }
    func showMenu(in view: NSView) {
        let menu = NSMenu()
        func add(_ title: String, _ selector: Selector, tag: Int = 0) {
            let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
            item.target = self; item.tag = tag; menu.addItem(item)
        }
        if audio.isDraft { add(String(localized: "Finish Recording", bundle: bundle), #selector(finishAction)) }
        else {
            for speed in [100, 125, 150, 200] { add(String(format: "%g×", Double(speed) / 100), #selector(rateAction(_:)), tag: speed) }
            menu.addItem(.separator())
        }
        add(String(localized: "Rename Audio…", bundle: bundle), #selector(renameAction))
        add(String(localized: "Export Audio…", bundle: bundle), #selector(exportAction))
        menu.addItem(.separator())
        add(String(localized: "Delete Block", bundle: bundle), #selector(deleteAction))
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: view.bounds.maxY), in: view)
    }
    @objc private func finishAction() { _ = finish() }
    @objc private func rateAction(_ item: NSMenuItem) { setRate(Float(item.tag) / 100) }
    @objc private func deleteAction() { editor?.deleteAudioBlock(blockID) }
    @objc private func renameAction() {
        guard let window = editor?.window else { return }
        let alert = NSAlert(); alert.messageText = String(localized: "Audio Name", bundle: bundle)
        let field = NSTextField(string: audio.name); field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: String(localized: "Save", bundle: bundle)); alert.addButton(withTitle: String(localized: "Cancel", bundle: bundle))
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            let name = String(field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).prefix(1024))
            guard !name.isEmpty else { return }
            var value = audio; value.name = name
            if editor?.updateAudio(value, blockID: blockID) != true {
                error = "Audio could not be saved. Your recording file is kept; retry saving."
            }
        }
    }
    @objc private func exportAction() {
        editor?.exportMedia(blockID: blockID)
    }
    isolated deinit { timer?.invalidate(); recorder?.stop(); player?.stop() }
}

@MainActor
final class AudioTextAttachment: NSTextAttachment {
    let model: AudioBlockModel?
    init(audio: NoteAudio, width: CGFloat, model: AudioBlockModel?) {
        self.model = model
        super.init(data: nil, ofType: nil)
        bounds = NSRect(x: 0, y: 0, width: max(80, width), height: 64)
        // Reserve TextKit geometry; PaperTextView owns and reuses the native
        // player at that exact frame, as it does for the active table editor.
        image = NSImage(size: bounds.size, flipped: false) { _ in true }
        allowsTextAttachmentView = false
    }
    required init?(coder: NSCoder) { nil }
}

private struct AudioBlockPlayer: View {
    @ObservedObject var model: AudioBlockModel
    @ObservedObject private var language = LanguageSettings.shared
    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 9) {
                Button {
                    if model.isRecording { model.toggleRecordingPause() }
                    else if model.audio.isDraft { _ = model.finish() }
                    else { model.togglePlayback() }
                } label: {
                    Image(systemName: model.isRecording ? (model.isPaused ? "mic.fill" : "pause.fill") : model.audio.isDraft ? "arrow.clockwise" : model.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 14, weight: .medium)).frame(width: 32, height: 32)
                        .background(model.ink.opacity(0.07), in: Circle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(model.isRecording ? Color.red : model.ink)
                .accessibilityLabel(model.isRecording ? String(localized: "Pause or resume recording", bundle: language.bundle) : model.audio.isDraft ? String(localized: "Recover Recording", bundle: language.bundle) : String(localized: "Play or pause audio", bundle: language.bundle))
                VStack(alignment: .leading, spacing: 4) {
                    GeometryReader { waveform in
                    AudioWaveform(ink: model.ink, peaks: model.isRecording ? model.livePeaks : model.audio.waveform,
                                  progress: model.audio.duration > 0 ? model.position / model.audio.duration : 0,
                                  recording: model.isRecording)
                        .frame(height: 23)
                        .contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                            model.seek(value.location.x / max(1, waveform.size.width))
                        })
                        .accessibilityElement().accessibilityLabel(String(localized: "Audio progress", bundle: language.bundle))
                        .accessibilityValue(NoteAudio.timestamp(model.position))
                        .accessibilityAdjustableAction { direction in model.seek((model.position + (direction == .increment ? 5 : -5)) / max(1, model.audio.duration)) }
                    }.frame(height: 23)
                    Text(model.errorMessage ?? (model.audio.isDraft
                        ? (model.isRecording ? String(localized: "Recording", bundle: language.bundle) + " " + NoteAudio.timestamp(model.position) : String(localized: "Unfinished Recording", bundle: language.bundle))
                        : NoteAudio.timestamp(model.position) + " / " + NoteAudio.timestamp(model.audio.duration)))
                        .font(.system(size: 10, design: .monospaced)).lineLimit(1)
                        .foregroundStyle(model.error != nil ? Color.red : model.ink.opacity(0.6))
                        .help(model.errorMessage ?? model.audio.name)
                }
                if model.audio.isDraft {
                    Button(String(localized: "Done", bundle: language.bundle)) { _ = model.finish() }.buttonStyle(.plain).font(.system(size: 11))
                } else if geometry.size.width >= 270 {
                    Button(String(format: "%g×", model.rate)) { model.setRate(model.rate < 1.25 ? 1.25 : model.rate < 1.5 ? 1.5 : model.rate < 2 ? 2 : 1) }
                        .buttonStyle(.plain).font(.system(size: 10)).frame(width: 30)
                }
                AudioMoreButton(model: model).frame(width: 22, height: 28)
            }
            .padding(.horizontal, 10).frame(height: 64)
            .background(model.ink.opacity(0.045), in: RoundedRectangle(cornerRadius: 12))
        }
        .frame(height: 64)
        .foregroundStyle(model.ink)
        .help(model.audio.name)
    }
}
private struct AudioMoreButton: NSViewRepresentable {
    let model: AudioBlockModel
    func makeNSView(context: Context) -> Button {
        let button = Button(); button.bezelStyle = .inline; button.isBordered = false
        button.image = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: nil)
        button.target = button; button.action = #selector(Button.openMenu); button.model = model
        return button
    }
    func updateNSView(_ button: Button, context: Context) {
        button.model = model; button.toolTip = String(localized: "Audio Options", bundle: model.bundle)
        button.setAccessibilityLabel(button.toolTip)
        button.contentTintColor = model.editor?.noteColor
    }
    final class Button: NSButton {
        weak var model: AudioBlockModel?
        @objc func openMenu() { model?.showMenu(in: self) }
    }
}
private struct AudioWaveform: View {
    let ink: Color
    let peaks: [Float]
    let progress: Double
    let recording: Bool
    var body: some View {
        Canvas { context, size in
            let count = max(1, Int(size.width / 4))
            for index in 0..<count {
                let peak = peaks.isEmpty ? 0 : peaks[min(peaks.count - 1, index * peaks.count / count)]
                let h = max(2, CGFloat(peak) * size.height)
                let rect = CGRect(x: CGFloat(index) * 4, y: (size.height - h) / 2, width: 2, height: h)
                context.fill(Path(roundedRect: rect, cornerRadius: 1), with: .color(recording ? .red.opacity(0.6) : ink.opacity(Double(index) / Double(count) <= progress ? 0.7 : 0.2)))
            }
        }
    }
}
