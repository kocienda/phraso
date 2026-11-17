// The document: a video, its transcript, the style being edited, and the preview time.
// Saved as a `.phraso` package (project.json, words.json, style.json) so a project can
// be reopened with its corrected words and its look intact; the video itself stays where
// it is and is found again by bookmark or path. Everything the views show comes from
// here; everything the engine does is called from here.

import AppKit
import AVFoundation
import Combine
import PhrasoKit
import UniformTypeIdentifiers

/// The document class `App/Info.plist` names, under a name both builds give it: the
/// package's module is PhrasoApp and the Xcode project's is Phraso.
@objc(PhrasoDocument)
@MainActor
final class Document: NSDocument, ObservableObject {
    /// What project.json holds. The transcript and the style are files of their own.
    struct ProjectFile: Codable {
        var phraso = 1
        var video: String?
        var bookmark: Data?
        var preset: String?
        var time: Double = 0
    }

    @Published var videoURL: URL?
    @Published var media: MediaInfo?
    @Published var transcript: Transcript?
    @Published var style: Style = (try? Presets.style(named: Presets.defaultStem)) ?? Style(name: "Outline", font: "Anton-Regular")
    @Published var presetName: String? = Presets.defaultStem
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

    /// The document's window.
    var window: NSWindow? { windowControllers.first?.window }

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

    override init() {
        super.init()
        reloadPresets()
        watchForEdits()
        watchPlayhead()
    }

    // MARK: the file

    /// Untitled documents are kept too, and come back at the next launch.
    override class var autosavesInPlace: Bool { true }

    override func makeWindowControllers() {
        addWindowController(DocumentWindowController(document: self))
    }

    /// A document with no video asks for one as soon as its window is up.
    func windowDidShow() {
        if videoURL == nil, !loadFromCommandLine() { chooseVideo() }
    }

    override func close() {
        pause()
        super.close()
    }

    /// Reading sets the document up as it was saved, which is not an edit to undo. The
    /// document controller reads on the main thread, since this class does not say it
    /// can read concurrently.
    override nonisolated func read(from fileWrapper: FileWrapper, ofType typeName: String) throws {
        try MainActor.assumeIsolated { try read(fileWrapper) }
    }

    private func read(_ fileWrapper: FileWrapper) throws {
        guard let files = fileWrapper.fileWrappers else { throw CocoaError(.fileReadCorruptFile) }
        undoManager?.disableUndoRegistration()
        defer { undoManager?.enableUndoRegistration() }
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
        }
    }

    override func fileWrapper(ofType typeName: String) throws -> FileWrapper {
        var project = ProjectFile(video: videoURL?.path, preset: presetName, time: time)
        project.bookmark = try? videoURL?.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var files: [String: FileWrapper] = [
            "project.json": FileWrapper(regularFileWithContents: try enc.encode(project)),
            "style.json": FileWrapper(regularFileWithContents: try enc.encode(style)),
        ]
        if let t = transcript { files["words.json"] = FileWrapper(regularFileWithContents: try enc.encode(t)) }
        return FileWrapper(directoryWithFileWrappers: files)
    }

    /// Style and transcript edits become undo steps on the document's undo manager,
    /// which is also what marks the document edited. `@Published` publishes before the
    /// value changes, so `style` is still the old value when the new one arrives.
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
        let files = Presets.files()
        presets = Presets.ordered(files.keys).compactMap { k in (try? Style.load(files[k]!)).map { (k, $0) } }
    }

    func choosePreset(_ stem: String) {
        guard let p = presets.first(where: { $0.stem == stem }) else { return }
        style = p.style
        presetName = stem
    }

    // MARK: video and transcript

    /// Any movie or sound file AVFoundation can open.
    static let mediaTypes: [UTType] = [.audiovisualContent, .movie, .video, .audio]

    /// Ask for the video in a sheet on the window. A new document asks at once, and one
    /// that is refused its video has nothing to be, so it closes.
    func chooseVideo() {
        guard let w = window, w.attachedSheet == nil else { return }
        let panel = NSOpenPanel()
        panel.message = "Choose video or sound file to caption"
        panel.prompt = "Choose"
        panel.allowedContentTypes = Document.mediaTypes
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.beginSheetModal(for: w) { result in
            if result == .OK, let url = panel.url {
                self.load(url)
            } else if self.videoURL == nil, self.fileURL == nil {
                self.close()
            }
        }
    }

    @objc func chooseVideo(_ sender: Any?) { chooseVideo() }

    /// Caption `url`, as opened from the Finder or dropped on the app's icon.
    static func open(media url: URL) {
        let controller = NSDocumentController.shared
        let docs = controller.documents.compactMap { $0 as? Document }
        if let doc = docs.first(where: { $0.videoURL?.standardizedFileURL == url.standardizedFileURL }) {
            doc.showWindows()
            return
        }
        // a new window still asking for its video takes this one; its sheet then goes
        if let doc = docs.first(where: { $0.videoURL == nil && $0.fileURL == nil && !$0.isDocumentEdited }) {
            doc.load(url)
            (doc.window?.attachedSheet as? NSSavePanel)?.cancel(nil)
            doc.showWindows()
            return
        }
        do {
            guard let doc = try controller.makeUntitledDocument(ofType: controller.defaultType ?? "com.kocienda.phraso.project") as? Document else { return }
            controller.addDocument(doc)
            doc.load(url)
            doc.makeWindowControllers()
            doc.showWindows()
        } catch {
            controller.presentError(error)
        }
    }

    @objc func exportMovie(_ sender: Any?) { export() }
    @objc func saveStylePreset(_ sender: Any?) { savePreset() }
    @objc func togglePlayback(_ sender: Any?) { togglePlay() }
    @objc func stepBackward(_ sender: Any?) { step(-1) }
    @objc func stepForward(_ sender: Any?) { step(1) }
    @objc func goToStart(_ sender: Any?) { toStart() }
    @objc func goToEnd(_ sender: Any?) { toEnd() }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case #selector(exportMovie(_:)): return transcript != nil && !isBusy
        case #selector(togglePlayback(_:)):
            (item as? NSMenuItem)?.title = isPlaying ? "Pause" : "Play"
            return transportHasKeys
        case #selector(stepBackward(_:)), #selector(stepForward(_:)), #selector(goToStart(_:)), #selector(goToEnd(_:)):
            return transportHasKeys
        default: return super.validateUserInterfaceItem(item)
        }
    }

    /// Space, the arrows, Home and End move the playhead the way every player has them;
    /// but not while a field or a control has the keyboard, or a sheet is up, when a
    /// disabled item leaves the key to them.
    private var transportHasKeys: Bool {
        guard duration > 0, let w = window, NSApp.keyWindow === w, w.attachedSheet == nil else { return false }
        return !(w.firstResponder is NSText) && !(w.firstResponder is NSControl)
    }

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
                        transcript = try await Transcriber.transcribe(url) { m in Task { @MainActor in self.status = m } }
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
        if isFresh(i) {
            // a word's first text belongs to putting it in, so one Undo takes it out
            fresh = nil
            undoManager?.disableUndoRegistration()
            transcript = t
            undoManager?.enableUndoRegistration()
        } else {
            transcript = t
        }
    }

    /// Ends the card after word `i` whatever the count, or lets it run on again. Neither
    /// the words nor their times move.
    func toggleBreak(_ i: Int) {
        guard var t = transcript, t.words.indices.contains(i) else { return }
        t.words[i].break.toggle()
        transcript = t
        undoManager?.setActionName(t.words[i].break ? "Add Card Break" : "Remove Card Break")
    }

    /// Takes a word out of the transcript; the words either side keep their times.
    func removeWord(_ i: Int) {
        guard var t = transcript, t.words.indices.contains(i) else { return }
        if isFresh(i), let u = undoManager, u.canUndo, u.undoActionName == "Insert Word" {
            // a word put in and left empty was never there
            fresh = nil
            u.undo()
            return
        }
        t.words.remove(at: i)
        transcript = t
    }

    /// Puts an empty word in before word `i` (after the last when `i` is the count).
    /// It takes the pause between its neighbours, or when they abut, the second half of
    /// the word before, whose end moves to the middle; so no other word moves. At the
    /// ends it takes up to half a second before the first word or after the last.
    func insertWord(at i: Int) {
        guard var t = transcript, (0...t.words.count).contains(i) else { return }
        let w = t.words
        let limit = max(t.duration, duration, w.last?.end ?? 0)
        var start: Double, end: Double
        if i > 0, i < w.count, w[i].start > w[i - 1].end {
            (start, end) = (w[i - 1].end, w[i].start)
        } else if i == 0, let first = w.first, first.start > 0 {
            (start, end) = (max(0, first.start - 0.5), first.start)
        } else if i == w.count, let last = w.last, last.end < limit {
            (start, end) = (last.end, min(limit, last.end + 0.5))
        } else if i > 0 {
            // abutting, or the last word runs to the end: halve the word before
            let mid = (w[i - 1].start + w[i - 1].end) / 2
            (start, end) = (mid, w[i - 1].end)
            t.words[i - 1].end = mid
        } else if let first = w.first {
            // the first word starts at zero: take its first half
            let mid = (first.start + first.end) / 2
            (start, end) = (first.start, mid)
            t.words[0].start = mid
        } else {
            (start, end) = (0, min(0.5, limit))
        }
        t.words.insert(Word("", start, end), at: i)
        transcript = t
        undoManager?.setActionName("Insert Word")
        fresh = (i, t)
    }

    /// The word `insertWord` put in, while nothing else has changed the transcript.
    private var fresh: (index: Int, transcript: Transcript)?
    private func isFresh(_ i: Int) -> Bool {
        guard let f = fresh else { return false }
        return f.index == i && f.transcript == transcript
    }

    func retranscribe() {
        guard let url = videoURL else { return }
        isBusy = true
        status = "Transcribing…"
        Task {
            do {
                transcript = try await Transcriber.transcribe(url) { m in Task { @MainActor in self.status = m } }
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
                    self.status = "Wrote \(outputs.movie.lastPathComponent). Drag it onto your editor's timeline."
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
