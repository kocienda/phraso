// The document window's views: the preview over the transcript on the left, the presets
// and the inspector on the right. A video or sound file dropped anywhere on them is
// loaded.

import AppKit
import AVFoundation
import Combine
import PhrasoKit

final class ContentView: NSView {
    private let doc: Document
    private var sidebarWidth: NSLayoutConstraint!
    private var bag: Set<AnyCancellable> = []

    init(doc: Document) {
        self.doc = doc
        super.init(frame: NSRect(x: 0, y: 0, width: 1180, height: 728))
        let preview = PreviewView(doc: doc)
        let transcript = TranscriptView(doc: doc)
        let sidebar = Sidebar(doc: doc)
        let across = separator(), down = separator()
        for v in [preview, across, transcript, down, sidebar] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        // a scroll bar that is always shown takes its width beside the pane, not out of it
        sidebarWidth = sidebar.widthAnchor.constraint(equalToConstant: Pane.width + Pane.scroller)
        // the preview and the transcript share the height, the transcript keeping 160
        let shared = preview.heightAnchor.constraint(equalTo: transcript.heightAnchor)
        shared.priority = .defaultHigh
        NSLayoutConstraint.activate([
            sidebar.topAnchor.constraint(equalTo: topAnchor),
            sidebar.bottomAnchor.constraint(equalTo: bottomAnchor),
            sidebar.trailingAnchor.constraint(equalTo: trailingAnchor),
            sidebarWidth,
            down.topAnchor.constraint(equalTo: topAnchor),
            down.bottomAnchor.constraint(equalTo: bottomAnchor),
            down.trailingAnchor.constraint(equalTo: sidebar.leadingAnchor),
            down.widthAnchor.constraint(equalToConstant: 1),
            preview.topAnchor.constraint(equalTo: topAnchor),
            preview.leadingAnchor.constraint(equalTo: leadingAnchor),
            preview.trailingAnchor.constraint(equalTo: down.leadingAnchor),
            preview.widthAnchor.constraint(greaterThanOrEqualToConstant: 640),
            across.topAnchor.constraint(equalTo: preview.bottomAnchor),
            across.leadingAnchor.constraint(equalTo: leadingAnchor),
            across.trailingAnchor.constraint(equalTo: down.leadingAnchor),
            across.heightAnchor.constraint(equalToConstant: 1),
            transcript.topAnchor.constraint(equalTo: across.bottomAnchor),
            transcript.leadingAnchor.constraint(equalTo: leadingAnchor),
            transcript.trailingAnchor.constraint(equalTo: down.leadingAnchor),
            transcript.bottomAnchor.constraint(equalTo: bottomAnchor),
            transcript.heightAnchor.constraint(greaterThanOrEqualToConstant: 160),
            shared,
        ])
        NotificationCenter.default.publisher(for: NSScroller.preferredScrollerStyleDidChangeNotification)
            .sink { [weak self] _ in self?.sidebarWidth.constant = Pane.width + Pane.scroller }
            .store(in: &bag)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func separator() -> NSBox {
        let b = NSBox()
        b.boxType = .separator
        return b
    }

    // MARK: drop

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        dropped(sender) == nil ? [] : .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let url = dropped(sender) else { return false }
        doc.load(url)
        return true
    }

    /// The file being dropped, unless it is this document's own video, or the caption
    /// movie dragged from the title bar and let go over this window on its way somewhere
    /// else.
    private func dropped(_ info: NSDraggingInfo) -> URL? {
        let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
        guard let url = urls?.first as? URL else { return nil }
        let own = [doc.videoURL, doc.lastExport?.movie].compactMap { $0?.standardizedFileURL }
        return own.contains(url.standardizedFileURL) ? nil : url
    }
}

/// The footage playing with the caption drawn over it at the playhead, and the media
/// controls under it: the scrubber, then the playhead's time, the transport, the length.
final class PreviewView: NSView {
    private let doc: Document
    private let picture = NSView()
    private let player = PlayerView()
    /// The stand-in for a sound file's missing picture.
    private let grey = NSView()
    private let caption = NSView()
    private let empty: NSStackView
    private let scrubber = NSSlider()
    private let now = PreviewView.timeLabel(.labelColor, .left)
    private let length = PreviewView.timeLabel(.secondaryLabelColor, .right)
    private var play: NSButton!
    private var transport: [NSButton] = []
    private var bag: Set<AnyCancellable> = []
    private var updating = false

    init(doc: Document) {
        self.doc = doc
        let icon = NSImageView(image: NSImage(systemSymbolName: "film.stack", accessibilityDescription: nil)!)
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 48, weight: .regular)
        icon.contentTintColor = .secondaryLabelColor
        let prompt = NSTextField(labelWithString: "Drop a video or a sound file here")
        prompt.textColor = .secondaryLabelColor
        let choose = NSButton(title: "Choose Video…", target: doc, action: #selector(Document.chooseVideo(_:)))
        empty = NSStackView(views: [icon, prompt, choose])
        empty.orientation = .vertical
        empty.spacing = 12
        super.init(frame: .zero)

        picture.wantsLayer = true
        picture.layer?.backgroundColor = NSColor.black.cgColor
        player.playerLayer.player = doc.player
        grey.wantsLayer = true
        grey.layer?.backgroundColor = NSColor(white: 0.45, alpha: 1).cgColor
        caption.wantsLayer = true
        caption.layer?.contentsGravity = .resize
        for v in [player, grey, caption] { picture.addSubview(v) }
        empty.translatesAutoresizingMaskIntoConstraints = false
        picture.addSubview(empty)

        scrubber.controlSize = .small
        scrubber.minValue = 0
        scrubber.isContinuous = true
        scrubber.refusesFirstResponder = true
        scrubber.target = self
        scrubber.action = #selector(scrub(_:))
        play = button("play.fill", 20, #selector(Document.togglePlayback(_:)))
        transport = [
            button("backward.end.fill", 14, #selector(Document.goToStart(_:)), "Go to Start (Home)"),
            button("backward.frame.fill", 14, #selector(Document.stepBackward(_:)), "Back One Frame (←)"),
            play,
            button("forward.frame.fill", 14, #selector(Document.stepForward(_:)), "Forward One Frame (→)"),
            button("forward.end.fill", 14, #selector(Document.goToEnd(_:)), "Go to End (End)"),
        ]
        let buttons = NSStackView(views: transport)
        buttons.spacing = 22
        let line = NSBox()
        line.boxType = .separator
        for v in [picture, line, scrubber, now, buttons, length] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            picture.topAnchor.constraint(equalTo: topAnchor),
            picture.leadingAnchor.constraint(equalTo: leadingAnchor),
            picture.trailingAnchor.constraint(equalTo: trailingAnchor),
            empty.centerXAnchor.constraint(equalTo: picture.centerXAnchor),
            empty.centerYAnchor.constraint(equalTo: picture.centerYAnchor),
            line.topAnchor.constraint(equalTo: picture.bottomAnchor),
            line.leadingAnchor.constraint(equalTo: leadingAnchor),
            line.trailingAnchor.constraint(equalTo: trailingAnchor),
            line.heightAnchor.constraint(equalToConstant: 1),
            // the controls: 6 over the scrubber, 2 under it, 8 under the row, 12 at the sides
            scrubber.topAnchor.constraint(equalTo: line.bottomAnchor, constant: 6),
            scrubber.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            scrubber.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            buttons.topAnchor.constraint(equalTo: scrubber.bottomAnchor, constant: 2),
            buttons.centerXAnchor.constraint(equalTo: centerXAnchor),
            buttons.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            play.widthAnchor.constraint(equalToConstant: 24),
            now.leadingAnchor.constraint(equalTo: scrubber.leadingAnchor),
            now.centerYAnchor.constraint(equalTo: buttons.centerYAnchor),
            now.widthAnchor.constraint(equalToConstant: 90),
            length.trailingAnchor.constraint(equalTo: scrubber.trailingAnchor),
            length.centerYAnchor.constraint(equalTo: buttons.centerYAnchor),
            length.widthAnchor.constraint(equalToConstant: 90),
        ])
        doc.objectWillChange.sink { [weak self] in self?.setNeedsUpdate() }.store(in: &bag)
        update()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private static func timeLabel(_ color: NSColor, _ alignment: NSTextAlignment) -> NSTextField {
        let t = NSTextField(labelWithString: "00:00:00")
        t.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        t.textColor = color
        t.alignment = alignment
        return t
    }

    private func button(_ symbol: String, _ size: CGFloat, _ action: Selector, _ help: String? = nil) -> NSButton {
        let b = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: help)!, target: doc, action: action)
        b.isBordered = false
        b.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: size, weight: .regular)
        b.refusesFirstResponder = true
        b.toolTip = help
        b.heightAnchor.constraint(equalToConstant: 24).isActive = true
        return b
    }

    @objc private func scrub(_ sender: NSSlider) {
        doc.time = sender.doubleValue
    }

    /// The document says it is about to change; look once it has, however many changes
    /// come in the meantime.
    private func setNeedsUpdate() {
        guard !updating else { return }
        updating = true
        DispatchQueue.main.async { self.updating = false; self.update() }
    }

    private func update() {
        let hasMedia = doc.videoURL != nil
        empty.isHidden = hasMedia
        player.isHidden = !hasMedia || !doc.hasVideo
        grey.isHidden = !hasMedia || doc.hasVideo
        caption.isHidden = !hasMedia
        let duration = doc.duration
        scrubber.maxValue = max(duration, 0.001)
        scrubber.doubleValue = doc.time
        now.stringValue = timecode(doc.time)
        length.stringValue = timecode(duration)
        play.image = NSImage(systemSymbolName: doc.isPlaying ? "pause.fill" : "play.fill", accessibilityDescription: nil)
        play.toolTip = doc.isPlaying ? "Pause (Space)" : "Play (Space)"
        let ready = duration > 0
        scrubber.isEnabled = ready
        transport.forEach { $0.isEnabled = ready }
        needsLayout = true
        drawCaption()
    }

    override func layout() {
        super.layout()
        player.frame = picture.bounds
        let fit = fitted(in: picture.bounds.size)
        let r = NSRect(x: ((picture.bounds.width - fit.width) / 2).rounded(), y: ((picture.bounds.height - fit.height) / 2).rounded(),
                       width: fit.width, height: fit.height)
        if grey.frame != r { grey.frame = r }
        if caption.frame != r { caption.frame = r; drawCaption() }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        drawCaption()
    }

    /// The caption on the frame under the playhead, drawn at the screen's pixels.
    private func drawCaption() {
        guard doc.videoURL != nil else { caption.layer?.contents = nil; return }
        let scale = window?.backingScaleFactor ?? 2
        let size = CGSize(width: (caption.frame.width * scale).rounded(), height: (caption.frame.height * scale).rounded())
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        caption.layer?.contents = doc.caption(frame: doc.frame, size: size)
        CATransaction.commit()
    }

    /// The picture's frame inside the view: the video's shape, as large as fits.
    private func fitted(in size: CGSize) -> CGSize {
        let aspect = CGFloat(doc.media?.width ?? 16) / CGFloat(doc.media?.height ?? 9)
        var w = size.width, h = w / aspect
        if h > size.height { h = size.height; w = h * aspect }
        return CGSize(width: w.rounded(), height: h.rounded())
    }

    /// Minutes, seconds and frames.
    private func timecode(_ t: Double) -> String {
        let fps = doc.frameRate.fps
        let f = Int((t * fps).rounded())
        let whole = Int(Double(f) / fps)
        return String(format: "%02d:%02d:%02d", whole / 60, whole % 60, f - Int(Double(whole) * fps))
    }
}

/// The player's picture, fitted to the view the way the caption over it is.
final class PlayerView: NSView {
    let playerLayer = AVPlayerLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        playerLayer.videoGravity = .resizeAspect
        playerLayer.backgroundColor = .black
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func makeBackingLayer() -> CALayer { playerLayer }
}
