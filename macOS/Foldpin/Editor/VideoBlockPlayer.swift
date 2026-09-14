import AppKit
import AVKit

@MainActor
final class VideoTextAttachment: NSTextAttachment {
    static func size(video: NoteVideo, width: CGFloat) -> NSSize {
        NSSize(width: width, height: min(400, max(120, width * video.pixelHeight / video.pixelWidth)) + 32)
    }
    init(video: NoteVideo, width: CGFloat) {
        super.init(data: nil, ofType: nil)
        bounds = NSRect(origin: .zero, size: Self.size(video: video, width: width))
        image = NSImage(size: bounds.size, flipped: true) { rect in
            NSColor.black.withAlphaComponent(0.08).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8).fill()
            return true
        }
        allowsTextAttachmentView = false
    }
    required init?(coder: NSCoder) { nil }
}

@MainActor
final class VideoBlockModel {
    static weak var playing: VideoBlockModel?
    let blockID: UUID
    var video: NoteVideo
    let file: NoteFile
    private(set) var player: AVPlayer?
    private var observation: NSKeyValueObservation?
    private var statusObservation: NSKeyValueObservation?
    private var position = CMTime.zero
    weak var view: VideoBlockView?
    private(set) var failed = false

    init(blockID: UUID, video: NoteVideo, file: NoteFile) {
        self.blockID = blockID; self.video = video; self.file = file
    }
    func play() -> AVPlayer? {
        guard AudioBlockModel.recording == nil, file.libraryPath?.writable != false else { return nil }
        Self.playing?.pause(); AudioBlockModel.playing?.pause()
        if player == nil {
            let item = AVPlayerItem(asset: NoteVideoImporter.asset(at: file.videoURL(video)))
            let player = AVPlayer(playerItem: item)
            player.actionAtItemEnd = .pause
            self.player = player
            failed = false
            statusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
                guard item.status == .failed else { return }
                Task { @MainActor [weak self, weak item] in
                    guard let self, let item, self.player?.currentItem === item else { return }
                    failed = true; pause(); view?.refresh()
                }
            }
            observation = player.observe(\.rate, options: [.new]) { [weak self] _, _ in
                Task { @MainActor [weak self] in
                    guard let self, let player = self.player, player.rate > 0 else { return }
                    guard AudioBlockModel.recording == nil else { pause(); return }
                    if Self.playing !== self { Self.playing?.pause() }
                    AudioBlockModel.playing?.pause(); Self.playing = self
                }
            }
            if position.seconds.isFinite, position.seconds > 0, position.seconds < video.duration - 0.05 {
                player.seek(to: position)
            }
        }
        Self.playing = self
        player?.play()
        return player
    }
    func pause() {
        player?.pause()
        if Self.playing === self { Self.playing = nil }
    }
    func detach() {
        pause()
        if let player { position = player.currentTime() }
        observation = nil; statusObservation = nil
        player?.replaceCurrentItem(with: nil); player = nil
    }
    isolated deinit { player?.pause() }
}

/// Only visible blocks have a view; the decoder is created on explicit Play.
@MainActor
final class VideoPlayerSurface: AVPlayerView {
    var blockMenu: (() -> NSMenu?)?
    override func menu(for event: NSEvent) -> NSMenu? { blockMenu?() }
}

@MainActor
final class VideoBlockView: NSView {
    let model: VideoBlockModel
    weak var editor: PaperTextView?
    let playerView = VideoPlayerSurface()
    private let poster = NSImageView()
    private let playButton = NSButton()
    private let nameLabel = NSTextField(labelWithString: "")
    private let moreButton = NSButton()
    override var isFlipped: Bool { true }

    init(model: VideoBlockModel, editor: PaperTextView) {
        self.model = model; self.editor = editor
        super.init(frame: .zero)
        wantsLayer = true; layer?.cornerRadius = 8; layer?.masksToBounds = true
        poster.image = NSImage(contentsOf: model.file.videoPosterURL(model.video))
        poster.imageScaling = .scaleProportionallyUpOrDown
        poster.wantsLayer = true; poster.layer?.backgroundColor = NSColor.black.cgColor
        playerView.controlsStyle = .inline
        playerView.videoGravity = .resizeAspect
        playerView.showsFullScreenToggleButton = false
        playerView.allowsPictureInPicturePlayback = false
        playerView.isHidden = true
        playButton.image = NSImage(systemSymbolName: "play.circle.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 42, weight: .regular))
        playButton.contentTintColor = .white; playButton.isBordered = false
        playButton.target = self; playButton.action = #selector(playVideo)
        moreButton.image = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: nil)
        moreButton.isBordered = false; moreButton.target = self; moreButton.action = #selector(showMenu)
        nameLabel.font = .systemFont(ofSize: 11)
        nameLabel.lineBreakMode = .byTruncatingMiddle
        for child in [poster, playerView, playButton, nameLabel, moreButton] { addSubview(child) }
        model.view = self
        playerView.blockMenu = { [weak self] in
            guard let self else { return nil }
            return self.editor?.makeBlockActionMenu(blockID: self.model.blockID)
        }
        refresh()
    }
    required init?(coder: NSCoder) { nil }
    func refreshPoster() { poster.image = NSImage(contentsOf: model.file.videoPosterURL(model.video)) }
    func refresh() {
        let bundle = LanguageSettings.shared.bundle
        let text = model.failed ? String(localized: "Could not play video. Check that the original file is available.", bundle: bundle)
            : model.video.name + " · " + NoteAudio.timestamp(model.video.duration)
        nameLabel.stringValue = text; nameLabel.toolTip = text
        nameLabel.textColor = editor?.noteColor ?? .labelColor
        moreButton.contentTintColor = nameLabel.textColor
        moreButton.toolTip = String(localized: "Video actions", bundle: bundle)
        moreButton.setAccessibilityLabel(moreButton.toolTip)
        playButton.toolTip = String(localized: "Play video", bundle: bundle)
        playButton.setAccessibilityLabel(playButton.toolTip)
        playerView.setAccessibilityLabel(model.video.name)
        if model.failed {
            playerView.isHidden = true; poster.isHidden = false; playButton.isHidden = false
        }
    }
    override func layout() {
        super.layout()
        let area = NSRect(x: 0, y: 0, width: bounds.width, height: max(0, bounds.height - 32))
        poster.frame = area; playerView.frame = area
        playButton.frame = NSRect(x: area.midX - 26, y: area.midY - 26, width: 52, height: 52)
        nameLabel.frame = NSRect(x: 8, y: area.maxY + 8, width: max(0, bounds.width - 44), height: 16)
        moreButton.frame = NSRect(x: max(0, bounds.width - 32), y: area.maxY + 2, width: 28, height: 28)
    }
    @objc private func playVideo() {
        if model.failed { playerView.player = nil; model.detach() }
        guard let player = model.play() else {
            let alert = NSAlert()
            alert.messageText = String(localized: "Finish the recording before playing video.", bundle: LanguageSettings.shared.bundle)
            if let window { alert.beginSheetModal(for: window) }
            return
        }
        playerView.player = player
        refresh()
        playerView.isHidden = false; poster.isHidden = true; playButton.isHidden = true
    }
    @objc private func showMenu() {
        editor?.makeBlockActionMenu(blockID: model.blockID)?.popUp(positioning: nil,
            at: NSPoint(x: 0, y: moreButton.bounds.maxY), in: moreButton)
    }
    override func menu(for event: NSEvent) -> NSMenu? { editor?.makeBlockActionMenu(blockID: model.blockID) }
    func detach() { playerView.player = nil; model.detach() }
    isolated deinit {
        if model.view === self { model.view = nil; model.detach() }
    }
}
