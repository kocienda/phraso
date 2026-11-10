// The document: a video, its transcript, the style being edited, and the preview time.
// Saved as a `.phraso` package (project.json, words.json, style.json) so a project can
// be reopened with its corrected words and its look intact; the video itself stays where
// it is and is found again by bookmark or path. Everything the views show comes from
// here; everything the engine does is called from here.

import AppKit
import AVFoundation
import Combine
import PhrasoKit
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static let phrasoProject = UTType(exportedAs: "com.kocienda.phraso.project", conformingTo: .package)
}

@MainActor
final class Document: @preconcurrency ReferenceFileDocument, ObservableObject {
    static var readableContentTypes: [UTType] { [.phrasoProject] }

    /// What project.json holds. The transcript and the style are files of their own.
    struct ProjectFile: Codable {
        var phraso = 1
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
    /// True while the player runs; the playhead (`time`) then follows it.
    @Published var isPlaying = false
    /// False for a sound file, which the preview shows on grey.
    @Published var hasVideo = true
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
    /// The document's window, handed over by the view.
    weak var window: NSWindow?

    /// Close a new document whose video sheet was cancelled: with no video and no file
    /// of its own there is nothing in it to keep.
    func closeIfEmpty() {
        guard videoURL == nil, let w = window else { return }
        if let d = w.windowController?.document as? NSDocument {
            if d.fileURL == nil { d.close() }
        } else {
            w.close()
        }
    }

    /// The steps for the current transcript and style, on the video's frame rate.
    var plan: (steps: [RenderStep], frames: Int) {
        guard let t = transcript else { return ([], 0) }
        return Job.plan(t, style: style, frameRate: frameRate)
    }
    var frameRate: FrameRate { media?.frameRate ?? .fps30 }
    var duration: Double { media?.duration ?? transcript?.duration ?? 0 }

    private var bag: Set<AnyCancellable> = []

    /// Plays the video under the preview; the caption is drawn over it (`caption`).
    let player = AVPlayer()
    private var timeObserver: Any?
    private var endOfItem: AnyCancellable?
    /// Set while the player moves the playhead, so the move is not sent back as a seek.
    private var playerIsMoving = false

    init() {
        reloadPresets()
        watchForEdits()
        watchPlayhead()
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
        watchPlayhead()
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
            self.lastExport = nil
            self.undoManager?.registerUndo(withTarget: self) { d in d.style = old }
            self.undoManager?.setActionName("Change Style")
        }.store(in: &bag)
        $transcript.dropFirst().sink { [weak self] new in
            guard let self, new != self.transcript else { return }
            let old = self.transcript
            self.lastExport = nil
            self.undoManager?.registerUndo(withTarget: self) { d in d.transcript = old }
            self.undoManager?.setActionName("Edit Transcript")
        }.store(in: &bag)
    }

    /// `open Phraso.app --env PHRASO_VIDEO=talk.mov`, for scripts and checks. An
    /// environment variable rather than an argument: AppKit treats a bare path argument
    /// as a file to open at launch, and then no untitled document is made. Taken once.
    private static var tookCommandLineVideo = false
    func loadFromCommandLine() -> Bool {
        guard videoURL == nil, !Document.tookCommandLineVideo,
              let p = ProcessInfo.processInfo.environment["PHRASO_VIDEO"], !p.isEmpty else { return false }
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
        let asset = AVURLAsset(url: url)
        pause()
        let item = AVPlayerItem(asset: asset)
        player.replaceCurrentItem(with: item)
        endOfItem = NotificationCenter.default.publisher(for: AVPlayerItem.didPlayToEndTimeNotification, object: item)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.reachedEnd() }
        isBusy = true
        status = "Reading \(url.lastPathComponent)…"
        Task {
            do {
                hasVideo = !(try await asset.loadTracks(withMediaType: .video)).isEmpty
                media = try await MediaInfo.probe(url)
                seekPlayer(to: time)
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

    /// The frame under the playhead.
    var frame: Int { Int((time * frameRate.fps).rounded()) }

    private var planCache: (style: Style, transcript: Transcript?, frameRate: FrameRate, plan: (steps: [RenderStep], frames: Int))?
    private var captionCache: (key: [Int], step: RenderStep, style: Style, image: CGImage?)?

    /// The plan, worked out again only when the words, the style or the rate change: the
    /// playhead asks for it on every frame of playback.
    private var currentPlan: (steps: [RenderStep], frames: Int) {
        if let c = planCache, c.style == style, c.transcript == transcript, c.frameRate == frameRate { return c.plan }
        let p = plan
        planCache = (style, transcript, frameRate, p)
        return p
    }

    /// The caption on frame `f`, transparent, `size` pixels; nil when no card shows.
    /// A card holds for many frames, so the last picture is kept and drawn again only
    /// when the step, the pop, the size or the style changes.
    func caption(frame f: Int, size: CGSize) -> CGImage? {
        let w = Int(size.width), h = Int(size.height)
        guard w > 0, h > 0 else { return nil }
        let steps = currentPlan.steps
        let renderer = Renderer(style: style, width: w, height: h)
        var cursor = 0
        guard let (i, into) = MovieWriter.step(at: f, in: steps, cursor: &cursor) else { return nil }
        let pop = renderer.popScale(frameInStep: into)
        let key = [pop == 1 ? -1 : into, w, h]
        if let c = captionCache, c.key == key, c.step == steps[i], c.style == style { return c.image }
        let ctx = renderer.makeContext()
        try? renderer.draw(steps[i], into: ctx, pop: pop)
        let img = ctx.makeImage()
        captionCache = (key, steps[i], style, img)
        return img
    }

    // MARK: playback

    /// A playhead moved by anything but the player (the scrubber, a word, a step) seeks it.
    private func watchPlayhead() {
        $time.dropFirst().sink { [weak self] t in
            guard let self, !self.playerIsMoving else { return }
            self.seekPlayer(to: t)
        }.store(in: &bag)
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 60), queue: .main) { [weak self] t in
            MainActor.assumeIsolated {
                guard let self, self.isPlaying else { return }
                self.playerIsMoving = true
                self.time = min(max(t.seconds, 0), self.duration)
                self.playerIsMoving = false
            }
        }
    }

    private func seekPlayer(to t: Double) {
        guard player.currentItem != nil else { return }
        player.seek(to: CMTime(seconds: t, preferredTimescale: 60000), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func togglePlay() { isPlaying ? pause() : play() }

    func play() {
        guard player.currentItem != nil, duration > 0 else { return }
        // at the end, play from the start
        if frame >= Int((duration * frameRate.fps).rounded()) - 1 { time = 0 }
        isPlaying = true
        player.play()
    }

    /// Stop, with the playhead on the frame it stopped at.
    func pause() {
        guard isPlaying else { return }
        player.pause()
        isPlaying = false
        time = Double(frame) / frameRate.fps
    }

    private func reachedEnd() {
        guard isPlaying else { return }
        player.pause()
        isPlaying = false
        playerIsMoving = true
        time = duration
        playerIsMoving = false
    }

    /// Move the playhead `n` frames, stopping play.
    func step(_ n: Int) {
        pause()
        let last = Int((duration * frameRate.fps).rounded())
        time = Double(min(max(0, frame + n), last)) / frameRate.fps
    }

    func toStart() { pause(); time = 0 }
    func toEnd() { pause(); time = duration }

    /// The step under the playhead, for highlighting the transcript.
    var currentWordIndex: Int? {
        guard let t = transcript else { return nil }
        return t.words.lastIndex { $0.start <= time }
    }

    // MARK: export and presets

    func export() {
        guard let url = videoURL, let t = transcript else { return }
        pause()
        let xml = ExportSettings.fcpxml
        let panel = NSSavePanel()
        panel.message = xml ? "Location for movie and Final Cut XML file" : "Location for the caption movie"
        panel.nameFieldStringValue = url.deletingPathExtension().lastPathComponent + ".captions"
        panel.directoryURL = url.deletingLastPathComponent()
        panel.allowedContentTypes = [.quickTimeMovie]
        panel.showsTagField = false
        guard panel.runModal() == .OK, let out = panel.url else { return }
        var job = Job(video: url, style: style, outputDirectory: out.deletingLastPathComponent(),
                      name: out.deletingPathExtension().lastPathComponent)
        job.transcript = t
        job.codec = ExportSettings.codec
        job.quality = ExportSettings.quality
        job.lines = ExportSettings.lines
        job.matte = ExportSettings.matte
        job.writesWords = ExportSettings.words
        job.writesSubtitles = ExportSettings.subtitles
        job.writesFCPXML = xml
        let reveal = ExportSettings.reveal
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
                    self.status = "Wrote \(outputs.movie.lastPathComponent). Drag it onto the Final Cut timeline."
                    self.isBusy = false
                    if reveal {
                        NSWorkspace.shared.activateFileViewerSelecting([outputs.movie, outputs.fcpxml, outputs.subtitles, outputs.words].compactMap { $0 })
                    }
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
