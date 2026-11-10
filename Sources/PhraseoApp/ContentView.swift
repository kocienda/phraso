import PhraseoKit
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject var doc: Document
    @Environment(\.undoManager) private var undoManager

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                PreviewView()
                Divider()
                TranscriptView()
                    .frame(minHeight: 160, idealHeight: 220)
            }
            .frame(minWidth: 640)
            VStack(spacing: 0) {
                StyleGrid()
                    .frame(height: 230)
                Divider()
                StyleInspector()
            }
            .frame(minWidth: 340, idealWidth: 380, maxWidth: 460)
        }
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button { doc.askingForVideo = true } label: { Label("Choose Video", systemImage: "film") }
                    .help("Choose the video or sound file to caption (⇧⌘O)")
            }
            ToolbarItem(placement: .status) {
                HStack(spacing: 8) {
                    if doc.isBusy { ProgressView(value: doc.progress > 0 ? doc.progress : nil).frame(width: 120) }
                    Text(doc.status).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button { doc.savePreset() } label: { Label("Save Preset", systemImage: "square.and.arrow.down") }
                Button { doc.export() } label: { Label("Export", systemImage: "square.and.arrow.up") }
                    .disabled(doc.transcript == nil || doc.isBusy)
            }
        }
        .focusedSceneObject(doc)
        .background(WindowReader { w in w.initialFirstResponder = nil; w.makeFirstResponder(nil) })
        .fileImporter(isPresented: $doc.askingForVideo, allowedContentTypes: Document.mediaTypes) { result in
            if case .success(let url) = result { doc.load(url) }
        }
        .fileDialogMessage("Choose the video, or the sound file, to caption")
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
        .alert("Phraseo", isPresented: Binding(get: { doc.error != nil }, set: { if !$0 { doc.error = nil } })) {
            Button("OK") { doc.error = nil }
        } message: { Text(doc.error ?? "") }
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
                    Color.black
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

/// Hands the hosting window over once, so a new window does not start typing into the
/// first word of the transcript.
struct WindowReader: NSViewRepresentable {
    var onWindow: (NSWindow) -> Void
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { if let w = v.window { onWindow(w) } }
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
