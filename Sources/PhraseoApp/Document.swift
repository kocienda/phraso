// The document: a video, its transcript, the style being edited, and the preview time.
// Saved as a `.phraseo` package (project.json, words.json, style.json) so a project can
// be reopened with its corrected words and its look intact; the video itself stays where
// it is and is found again by bookmark or path. Everything the views show comes from
// here; everything the engine does is called from here.

import AppKit
import AVFoundation
import Combine
import PhraseoKit
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static let phraseoProject = UTType(exportedAs: "com.kocienda.phraseo.project", conformingTo: .package)
}

@MainActor
final class Document: @preconcurrency ReferenceFileDocument, ObservableObject {
    static var readableContentTypes: [UTType] { [.phraseoProject] }

    /// What project.json holds. The transcript and the style are files of their own.
    struct ProjectFile: Codable {
        var phraseo = 1
        var video: String?
        var bookmark: Data?
        var preset: String?
        var time: Double = 0
    }

    struct Snapshot {
        var project: ProjectFile
        var transcript: Transcript?
        var style: Style
    }

    @Published var videoURL: URL?
    @Published var media: MediaInfo?
    @Published var transcript: Transcript?
    @Published var style: Style = (try? Presets.style(named: "area")) ?? Style(name: "Area", font: "Anton")
    @Published var presetName: String? = "area"
    @Published var presets: [(stem: String, style: Style)] = []
    @Published var time: Double = 0
    @Published var status: String = "Choose a video to caption."
    @Published var isBusy = false
    @Published var progress: Double = 0
    @Published var lastExport: Job.Outputs?
    @Published var error: String?
    /// Drops the video sheet from the window. A new document asks at once.
    @Published var askingForVideo = false

    /// The window's undo manager, handed over by the view; edits register here so the
    /// document knows it is dirty and ⌘Z works.
    weak var undoManager: UndoManager?

    /// The steps for the current transcript and style, on the video's frame rate.
    var plan: (steps: [RenderStep], frames: Int) {
        guard let t = transcript else { return ([], 0) }
        return Job.plan(t, style: style, frameRate: frameRate)
    }
    var frameRate: FrameRate { media?.frameRate ?? .fps30 }
    var duration: Double { media?.duration ?? transcript?.duration ?? 0 }

    private var frameCache: [Int: CGImage] = [:]
    private var generator: AVAssetImageGenerator?
    private var bag: Set<AnyCancellable> = []

    init() {
        reloadPresets()
        watchForEdits()
    }

    init(configuration: ReadConfiguration) throws {
        reloadPresets()
        guard let files = configuration.file.fileWrappers else { throw CocoaError(.fileReadCorruptFile) }
        let project = try JSONDecoder().decode(ProjectFile.self, from: files["project.json"]?.regularFileContents ?? Data("{}".utf8))
        if let d = files["style.json"]?.regularFileContents { style = try JSONDecoder().decode(Style.self, from: d) }
        if let d = files["words.json"]?.regularFileContents { transcript = try JSONDecoder().decode(Transcript.self, from: d) }
        presetName = project.preset
        time = project.time
        var url: URL?
        if let b = project.bookmark {
            var stale = false
            url = try? URL(resolvingBookmarkData: b, options: [.withoutUI], bookmarkDataIsStale: &stale)
        }
        if url == nil, let p = project.video { url = URL(fileURLWithPath: p) }
        if let u = url, FileManager.default.fileExists(atPath: u.path) {
            load(u, keepingTranscript: true)
        } else {
            status = project.video.map { "The video is missing: \($0)" } ?? "Choose a video to caption."
            askingForVideo = true
        }
        watchForEdits()
    }

    func snapshot(contentType: UTType) throws -> Snapshot {
        var p = ProjectFile(video: videoURL?.path, preset: presetName, time: time)
        p.bookmark = try? videoURL?.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        return Snapshot(project: p, transcript: transcript, style: style)
    }

    nonisolated func fileWrapper(snapshot: Snapshot, configuration: WriteConfiguration) throws -> FileWrapper {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var files: [String: FileWrapper] = [
            "project.json": FileWrapper(regularFileWithContents: try enc.encode(snapshot.project)),
            "style.json": FileWrapper(regularFileWithContents: try enc.encode(snapshot.style)),
        ]
        if let t = snapshot.transcript { files["words.json"] = FileWrapper(regularFileWithContents: try enc.encode(t)) }
        return FileWrapper(directoryWithFileWrappers: files)
    }

    /// Style and transcript edits become undo steps, which is also what marks the
    /// document edited. `@Published` publishes before the value changes, so `style` is
    /// still the old value when the new one arrives.
    private func watchForEdits() {
        $style.dropFirst().sink { [weak self] new in
            guard let self, new != self.style else { return }
            let old = self.style
            self.undoManager?.registerUndo(withTarget: self) { d in d.style = old }
            self.undoManager?.setActionName("Change Style")
        }.store(in: &bag)
        $transcript.dropFirst().sink { [weak self] new in
            guard let self, new != self.transcript else { return }
            let old = self.transcript
            self.undoManager?.registerUndo(withTarget: self) { d in d.transcript = old }
            self.undoManager?.setActionName("Edit Transcript")
        }.store(in: &bag)
    }

    /// `open Phraseo.app --env PHRASEO_VIDEO=talk.mov`, for scripts and checks. An
    /// environment variable rather than an argument: AppKit treats a bare path argument
    /// as a file to open at launch, and then no untitled document is made. Taken once.
    private static var tookCommandLineVideo = false
    func loadFromCommandLine() -> Bool {
        guard videoURL == nil, !Document.tookCommandLineVideo,
              let p = ProcessInfo.processInfo.environment["PHRASEO_VIDEO"], !p.isEmpty else { return false }
        Document.tookCommandLineVideo = true
        load(URL(fileURLWithPath: p))
        return true
    }

    func reloadPresets() {
        presets = Presets.files().sorted { $0.key < $1.key }.compactMap { k, u in (try? Style.load(u)).map { (k, $0) } }
    }

    func choosePreset(_ stem: String) {
        guard let p = presets.first(where: { $0.stem == stem }) else { return }
        style = p.style
        presetName = stem
    }

    // MARK: video and transcript

    /// Any movie or sound file AVFoundation can open.
    static let mediaTypes: [UTType] = [.audiovisualContent, .movie, .video, .audio]

    func load(_ url: URL, keepingTranscript: Bool = false) {
        _ = url.startAccessingSecurityScopedResource()
        videoURL = url
        if !keepingTranscript { transcript = nil; time = 0 }
        lastExport = nil
        frameCache = [:]
        let asset = AVURLAsset(url: url)
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 1920, height: 1080)
        gen.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 10)
        gen.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 10)
        generator = gen
        isBusy = true
        status = "Reading \(url.lastPathComponent)…"
        Task {
            do {
                media = try await MediaInfo.probe(url)
                if keepingTranscript, let t = transcript {
                    status = "\(t.words.count) words."
                } else {
                    let sidecar = Job(video: url, style: style).wordsURL
                    if FileManager.default.fileExists(atPath: sidecar.path) {
                        transcript = try Transcript.load(sidecar)
                        status = "Loaded the transcript beside the video (\(sidecar.lastPathComponent))."
                    } else {
                        status = "Transcribing…"
                        transcript = try await Transcriber.transcribe(url) { [weak self] m in Task { @MainActor in self?.status = m } }
                        status = "\(transcript!.words.count) words. Pick a style, fix any words, then Export."
                    }
                    if let t = transcript, let first = t.words.first { time = first.start + 0.2 }
                }
            } catch {
                self.error = "\(error)"
                status = "Could not read \(url.lastPathComponent)."
            }
            isBusy = false
        }
    }

    func setWord(_ i: Int, text: String) {
        guard var t = transcript, t.words.indices.contains(i) else { return }
        t.words[i].text = text
        transcript = t
    }

    func retranscribe() {
        guard let url = videoURL else { return }
        isBusy = true
        status = "Transcribing…"
        Task {
            do {
                transcript = try await Transcriber.transcribe(url) { [weak self] m in Task { @MainActor in self?.status = m } }
                status = "\(transcript!.words.count) words."
            } catch { self.error = "\(error)" }
            isBusy = false
        }
    }

    // MARK: preview

    /// The video frame nearest `t`, scaled to fit 1920 wide, from a small cache.
    func footage(at t: Double) async -> CGImage? {
        guard let gen = generator else { return nil }
        let key = Int(t * 10)
        if let c = frameCache[key] { return c }
        let img = try? await gen.image(at: CMTime(seconds: t, preferredTimescale: 600)).image
        if let i = img {
            if frameCache.count > 200 { frameCache.removeAll() }
            frameCache[key] = i
        }
        return img
    }

    /// The caption picture at `t`, at preview size, composited over the footage if there is any.
    func preview(at t: Double, size: CGSize) async -> CGImage? {
        let (steps, frames) = plan
        let w = Int(size.width), h = Int(size.height)
        guard w > 0, h > 0 else { return nil }
        let renderer = Renderer(style: style, width: w, height: h)
        let writer = MovieWriter(renderer: renderer, frameRate: frameRate, frames: frames)
        let f = Int((t * frameRate.fps).rounded())
        let footage = await footage(at: t)
        let ctx = renderer.makeContext()
        if let bg = footage {
            ctx.draw(bg, in: CGRect(x: 0, y: 0, width: w, height: h))
        } else {
            ctx.setFillColor(CGColor(gray: 0.45, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        }
        if let card = try? writer.frame(f, of: steps) {
            ctx.draw(card, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        return ctx.makeImage()
    }

    /// The step under the playhead, for highlighting the transcript.
    var currentWordIndex: Int? {
        guard let t = transcript else { return nil }
        return t.words.lastIndex { $0.start <= time }
    }

    // MARK: export and presets

    func export() {
        guard let url = videoURL, let t = transcript else { return }
        let panel = NSSavePanel()
        panel.message = "Where the caption track (.mov + .fcpxml) goes"
        panel.nameFieldStringValue = url.deletingPathExtension().lastPathComponent + ".captions"
        panel.directoryURL = url.deletingLastPathComponent()
        panel.allowedContentTypes = [.quickTimeMovie]
        panel.showsTagField = false
        guard panel.runModal() == .OK, let out = panel.url else { return }
        var job = Job(video: url, style: style, outputDirectory: out.deletingLastPathComponent(),
                      name: out.deletingPathExtension().lastPathComponent)
        job.transcript = t
        isBusy = true
        progress = 0
        status = "Rendering…"
        Task.detached { [job] in
            do {
                let outputs = try await job.run { phase, frac in
                    Task { @MainActor in
                        self.progress = frac
                        self.status = phase == .rendering ? "Rendering \(Int(frac * 100))%…" : phase.rawValue.capitalized
                    }
                }
                await MainActor.run {
                    self.lastExport = outputs
                    self.status = "Wrote \(outputs.fcpxml.lastPathComponent). Import it into Final Cut (File > Import > XML)."
                    self.isBusy = false
                    NSWorkspace.shared.activateFileViewerSelecting([outputs.fcpxml, outputs.movie])
                }
            } catch {
                await MainActor.run { self.error = "\(error)"; self.isBusy = false; self.status = "Export failed." }
            }
        }
    }

    func savePreset() {
        let panel = NSSavePanel()
        panel.message = "Save this style as a preset"
        panel.directoryURL = Presets.userDirectory
        try? FileManager.default.createDirectory(at: Presets.userDirectory, withIntermediateDirectories: true)
        panel.nameFieldStringValue = style.name.lowercased().replacingOccurrences(of: " ", with: "-") + ".json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try style.write(to: url)
            reloadPresets()
            presetName = url.deletingPathExtension().lastPathComponent
            status = "Saved \(url.lastPathComponent)."
        } catch { self.error = "\(error)" }
    }

    func revealPresets() {
        try? FileManager.default.createDirectory(at: Presets.userDirectory, withIntermediateDirectories: true)
        NSWorkspace.shared.open(Presets.userDirectory)
    }
}
