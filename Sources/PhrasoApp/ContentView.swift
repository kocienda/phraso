import AVFoundation
import PhrasoKit
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject var doc: Document
    @Environment(\.undoManager) private var undoManager
    @State private var scroller = Pane.scroller

    var body: some View {
        columns
        .focusedSceneObject(doc)
        .background(WindowReader(found: { (w: NSWindow) in doc.window = w }))
        .fileImporter(isPresented: $doc.askingForVideo, allowedContentTypes: Document.mediaTypes, allowsMultipleSelection: false, onCompletion: chose, onCancellation: cancelled)
        .fileDialogMessage("Choose video or sound file to caption")
        .fileDialogConfirmationLabel("Choose")
        .task {
            doc.undoManager = undoManager
            if doc.videoURL == nil, !doc.loadFromCommandLine() { doc.askingForVideo = true }
        }
        .onChange(of: undoManager) { _, u in doc.undoManager = u }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            guard let p = providers.first else { return false }
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                // the caption movie dragged from the title bar and let go over this window
                // is on its way somewhere else, not a new video for this document
                if let u = url { Task { @MainActor in
                    let own = [doc.videoURL, doc.lastExport?.movie].compactMap { $0?.standardizedFileURL }
                    if !own.contains(u.standardizedFileURL) { doc.load(u) }
                } }
            }
            return true
        }
        .alert("Phraso", isPresented: Binding(get: { doc.error != nil }, set: { if !$0 { doc.error = nil } })) {
            Button("OK") { doc.error = nil }
        } message: { Text(doc.error ?? "") }
    }

    /// The preview over the transcript, the sidebar beside them, and the toolbar.
    private var columns: some View {
        HSplitView {
            VStack(spacing: 0) {
                PreviewView()
                Divider()
                TranscriptView()
                    .frame(minHeight: 160, idealHeight: 220)
            }
            .frame(minWidth: 640)
            sidebar
        }
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                // the icon beside the name, like a document's proxy icon: click to choose the
                // video, drag to take the exported caption movie onto the Final Cut timeline
                Button { doc.askingForVideo = true } label: { Label("Choose Video", systemImage: "film") }
                    .onDrag { doc.lastExport.map { NSItemProvider(object: $0.movie as NSURL) } ?? NSItemProvider() }
                    .help(doc.lastExport == nil
                          ? "Choose the video or sound file to caption (⇧⌘O). After an Export, drag from here to put the caption movie on the Final Cut timeline."
                          : "Drag onto the Final Cut timeline to add \(doc.lastExport!.movie.lastPathComponent). Click to choose another video (⇧⌘O).")
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button { doc.export() } label: { Label("Export", systemImage: "square.and.arrow.up") }
                    .disabled(doc.transcript == nil || doc.isBusy)
            }
        }
    }
}

extension ContentView {
    private func chose(_ result: Result<[URL], Error>) {
        if case .success(let urls) = result, let url = urls.first { doc.load(url) }
    }

    /// A new document that is refused its video has nothing to be: close it.
    private func cancelled() {
        DispatchQueue.main.async { doc.closeIfEmpty() }
    }

    /// The presets over the inspector, on the sidebar's grey.
    private var sidebar: some View {
        VStack(spacing: 0) {
            StyleGrid()
                .frame(height: 200)
            Divider()
            StyleInspector()
        }
        // a scroll bar that is always shown takes its width beside the pane, not out of it
        .frame(width: Pane.width + scroller)
        .background(Pane.background)
        .onReceive(NotificationCenter.default.publisher(for: NSScroller.preferredScrollerStyleDidChangeNotification)) { _ in
            scroller = Pane.scroller
        }
    }
}

/// The footage playing with the caption drawn over it at the playhead, and the media
/// controls under it: the scrubber, then the playhead's time, the transport, the length.
struct PreviewView: View {
    @EnvironmentObject var doc: Document
    @State private var keys: Any?

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geo in
                let fit = fitted(in: geo.size)
                ZStack {
                    SwiftUI.Color.black
                    if doc.videoURL == nil {
                        VStack(spacing: 12) {
                            Image(systemName: "film.stack").font(.system(size: 48)).foregroundStyle(.secondary)
                            Text("Drop a video or a sound file here").foregroundStyle(.secondary)
                            Button("Choose Video…") { doc.askingForVideo = true }
                        }
                    } else {
                        if doc.hasVideo {
                            PlayerLayerView(player: doc.player)
                        } else {
                            SwiftUI.Color(white: 0.45).frame(width: fit.width, height: fit.height)
                        }
                        if let img = doc.caption(frame: doc.frame, size: CGSize(width: (fit.width * 2).rounded(), height: (fit.height * 2).rounded())) {
                            Image(decorative: img, scale: 2).resizable().frame(width: fit.width, height: fit.height)
                        }
                    }
                }
            }
            Divider()
            controls
        }
        .onAppear { keys = installKeys() }
        .onDisappear { if let k = keys { NSEvent.removeMonitor(k) }; keys = nil }
    }

    private var controls: some View {
        VStack(spacing: 2) {
            Slider(value: $doc.time, in: 0...max(doc.duration, 0.001))
                .controlSize(.small)
            HStack(spacing: 0) {
                Text(timecode(doc.time)).frame(width: 90, alignment: .leading)
                Spacer()
                HStack(spacing: 22) {
                    transport("backward.end.fill", "Go to Start (Home)") { doc.toStart() }
                    transport("backward.frame.fill", "Back One Frame (←)") { doc.step(-1) }
                    transport(doc.isPlaying ? "pause.fill" : "play.fill", doc.isPlaying ? "Pause (Space)" : "Play (Space)", size: 20) { doc.togglePlay() }
                        .frame(width: 24)
                    transport("forward.frame.fill", "Forward One Frame (→)") { doc.step(1) }
                    transport("forward.end.fill", "Go to End (End)") { doc.toEnd() }
                }
                Spacer()
                Text(timecode(doc.duration)).foregroundStyle(.secondary).frame(width: 90, alignment: .trailing)
            }
            .font(.system(size: 12).monospacedDigit())
        }
        .disabled(doc.duration == 0)
        .padding(.horizontal, 12).padding(.top, 6).padding(.bottom, 8)
    }

    private func transport(_ symbol: String, _ help: String, size: CGFloat = 14, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: size)).frame(height: 24)
        }
        .buttonStyle(.borderless)
        .help(help)
    }

    /// The picture's frame inside the view: the video's shape, as large as fits.
    private func fitted(in size: CGSize) -> CGSize {
        let aspect = CGFloat(doc.media?.width ?? 16) / CGFloat(doc.media?.height ?? 9)
        var w = size.width, h = w / aspect
        if h > size.height { h = size.height; w = h * aspect }
        return CGSize(width: w.rounded(), height: h.rounded())
    }

    /// Space plays and pauses, the arrows step a frame, Home and End go to the ends, the
    /// way every player has them; but not while a field or a control has the keyboard.
    private func installKeys() -> Any? {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [doc] e in
            guard let w = e.window, w === doc.window, w.attachedSheet == nil,
                  e.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty,
                  !(w.firstResponder is NSText), !(w.firstResponder is NSControl), doc.duration > 0
            else { return e }
            switch e.keyCode {
            case 49: doc.togglePlay()
            case 123: doc.step(-1)
            case 124: doc.step(1)
            case 115: doc.toStart()
            case 119: doc.toEnd()
            default: return e
            }
            return nil
        }
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
struct PlayerLayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> NSView {
        let v = Host()
        v.wantsLayer = true
        v.playerLayer.player = player
        v.playerLayer.videoGravity = .resizeAspect
        v.playerLayer.backgroundColor = .black
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? Host)?.playerLayer.player = player
    }

    final class Host: NSView {
        let playerLayer = AVPlayerLayer()
        override func makeBackingLayer() -> CALayer { playerLayer }
    }
}

extension Style: Hashable {
    public func hash(into hasher: inout Hasher) {
        hasher.combine((try? JSONEncoder().encode(self)) ?? Data())
    }
}

/// Sets a document window up before it is shown: placed by the classic cascade (the
/// first at the top left of the screen, each next one a title bar down and across) at a
/// fixed size, with no opening animation; and, once it is up, with no word field holding
/// the keyboard, so a new window does not start typing into the transcript. A window
/// the system is restoring keeps the frame it was saved with.
struct WindowReader: NSViewRepresentable {
    var found: (NSWindow) -> Void = { _ in }

    func makeNSView(context: Context) -> NSView {
        let h = Hook()
        h.found = found
        return h
    }
    func updateNSView(_ nsView: NSView, context: Context) {}

    static let windowSize = NSSize(width: 1180, height: 780)
    @MainActor static var cascade = NSPoint.zero

    final class Hook: NSView {
        private var done = false
        private var intended: NSRect?
        var found: (NSWindow) -> Void = { _ in }

        override func viewWillMove(toWindow window: NSWindow?) {
            super.viewWillMove(toWindow: window)
            guard let w = window, !done else { return }
            done = true
            found(w)
            w.animationBehavior = .none
            // SwiftUI centres the window and shows it after this, and only the next turn of
            // the run loop can put it back; until then it is drawn fully transparent, so
            // the stop in the middle of the screen is never seen
            let placing = AppDelegate.finishedRestoring
            if placing { w.alphaValue = 0; place(w) }
            DispatchQueue.main.async {
                self.hold(w)
                if placing { w.alphaValue = 1 }
                w.initialFirstResponder = nil
                w.makeFirstResponder(nil)
            }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let w = window { hold(w) }
        }

        /// SwiftUI centres a new window after the view goes in; put it back on the cascade.
        private func hold(_ w: NSWindow) {
            if let r = intended, w.frame != r { w.setFrame(r, display: true) }
        }

        private func place(_ w: NSWindow) {
            guard let screen = (NSApp.mainWindow?.screen ?? NSScreen.main)?.visibleFrame else { return }
            let size = NSSize(width: min(WindowReader.windowSize.width, screen.width), height: min(WindowReader.windowSize.height, screen.height))
            var top = WindowReader.cascade
            // start (or start again) at the top left when there is no cascade yet or the next
            // window would run off the screen
            if top == .zero || top.x + size.width > screen.maxX || top.y - size.height < screen.minY {
                top = NSPoint(x: screen.minX, y: screen.maxY)
            }
            let frame = NSRect(x: top.x, y: top.y - size.height, width: size.width, height: size.height)
            w.setFrame(frame, display: false)
            intended = frame
            WindowReader.cascade = w.cascadeTopLeft(from: top)
        }
    }
}
