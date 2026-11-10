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
                if let u = url { Task { @MainActor in doc.load(u) } }
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
                Button { doc.askingForVideo = true } label: { Label("Choose Video", systemImage: "film") }
                    .help("Choose the video or sound file to caption (⇧⌘O)")
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button { doc.savePreset() } label: { Label("Save Preset", systemImage: "square.and.arrow.down") }
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

/// The footage with the caption drawn over it at the playhead, and the scrubber.
struct PreviewView: View {
    @EnvironmentObject var doc: Document
    @State private var image: CGImage?
    @State private var renderTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 8) {
            GeometryReader { geo in
                ZStack {
                    SwiftUI.Color.black
                    if let img = image {
                        Image(decorative: img, scale: 1).resizable().aspectRatio(contentMode: .fit)
                    } else if doc.videoURL == nil {
                        VStack(spacing: 12) {
                            Image(systemName: "film.stack").font(.system(size: 48)).foregroundStyle(.secondary)
                            Text("Drop a video or a sound file here").foregroundStyle(.secondary)
                            Button("Choose Video…") { doc.askingForVideo = true }
                        }
                    }
                }
                .onChange(of: previewKey) { _, _ in render(in: geo.size) }
                .onAppear { render(in: geo.size) }
            }
            HStack {
                Text(timecode(doc.time)).monospacedDigit().frame(width: 90, alignment: .leading)
                Slider(value: $doc.time, in: 0...max(doc.duration, 0.001))
                    .disabled(doc.duration == 0)
                Button { step(-1) } label: { Image(systemName: "backward.frame") }.disabled(doc.duration == 0)
                Button { step(1) } label: { Image(systemName: "forward.frame") }.disabled(doc.duration == 0)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
        }
    }

    /// Anything that changes the picture.
    private var previewKey: String {
        "\(doc.time)|\(doc.style.hashValue)|\(doc.transcript?.words.count ?? -1)|\(doc.transcript.map { $0.words.map(\.text).joined() }?.hashValue ?? 0)|\(doc.media?.width ?? 0)"
    }

    private func render(in size: CGSize) {
        renderTask?.cancel()
        let aspect = CGFloat(doc.media?.width ?? 16) / CGFloat(doc.media?.height ?? 9)
        var w = min(size.width, 1920), h = w / aspect
        if h > size.height { h = size.height; w = h * aspect }
        let px = CGSize(width: (w * 2).rounded(), height: (h * 2).rounded())
        renderTask = Task {
            let img = await doc.preview(at: doc.time, size: px)
            if !Task.isCancelled { image = img }
        }
    }

    private func step(_ n: Int) {
        let fps = doc.frameRate.fps
        doc.time = min(max(0, (doc.time * fps).rounded() / fps + Double(n) / fps), doc.duration)
    }

    private func timecode(_ t: Double) -> String {
        let fps = doc.frameRate.fps
        let f = Int((t * fps).rounded())
        let whole = Int(Double(f) / fps)
        return String(format: "%02d:%02d:%02d", whole / 60, whole % 60, f - Int(Double(whole) * fps))
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
            if AppDelegate.finishedRestoring { place(w) }
            DispatchQueue.main.async {
                self.hold(w)
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
