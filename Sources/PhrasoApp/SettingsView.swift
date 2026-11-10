import AppKit
import PhrasoKit

/// What the app remembers between documents. One topic so far: what an Export writes.
/// Each value here is read with the same default its control shows before it is touched.
enum ExportSettings {
    static let codecKey = "exportCodec"
    static let qualityKey = "exportQuality"
    static let linesKey = "exportLines"
    static let matteKey = "exportMatte"
    static let wordsKey = "exportWords"
    static let subtitlesKey = "exportSubtitles"
    static let fcpxmlKey = "exportFCPXML"
    static let revealKey = "exportReveal"

    private static var d: UserDefaults { .standard }

    static var codec: Codec { d.string(forKey: codecKey).flatMap(Codec.init(rawValue:)) ?? .hevc }
    static var quality: Double { d.object(forKey: qualityKey) as? Double ?? MovieWriter.defaultQuality }
    /// The movie's shorter side, or nil for the video's own size.
    static var lines: Int? { (d.object(forKey: linesKey) as? Int).flatMap { $0 > 0 ? $0 : nil } }
    static var matte: Matte { d.string(forKey: matteKey).flatMap(Matte.init(rawValue:)) ?? .clear }
    static var words: Bool { d.object(forKey: wordsKey) as? Bool ?? true }
    static var subtitles: Bool { d.object(forKey: subtitlesKey) as? Bool ?? false }
    static var fcpxml: Bool { d.object(forKey: fcpxmlKey) as? Bool ?? false }
    static var reveal: Bool { d.object(forKey: revealKey) as? Bool ?? true }

    /// The sizes offered, by the movie's shorter side; 0 is the video's own.
    static let sizes: [(lines: Int, label: String)] = [
        (0, "Same as the video"), (2160, "2160p (4K)"), (1440, "1440p"), (1080, "1080p (HD)"), (720, "720p"),
    ]
}

/// The Settings window (⌘,): a topic per tab in its toolbar, each one a page.
final class SettingsWindowController: NSWindowController {
    @MainActor static let shared = SettingsWindowController()

    private init() {
        let tabs = NSTabViewController()
        tabs.tabStyle = .toolbar
        let page = MovieExportSettings()
        page.title = "Movie Export"  // the window takes the selected page's title
        let item = NSTabViewItem(viewController: page)
        item.label = "Movie Export"
        item.image = NSImage(systemSymbolName: "film", accessibilityDescription: nil)
        tabs.addTabViewItem(item)
        let w = NSWindow(contentViewController: tabs)
        w.styleMask = [.titled, .closable]
        w.toolbarStyle = .preference
        w.animationBehavior = .none
        super.init(window: w)
        w.center()
        w.setFrameAutosaveName("Settings")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
}

/// What an Export writes: the caption movie's format, size and background, and the
/// files that go beside it. Its frame rate is always the video's own, so every word
/// changes on a frame of the footage.
final class MovieExportSettings: NSViewController {
    private let d = UserDefaults.standard
    private let codec = NSPopUpButton()
    private let quality = NSSlider()
    private let percent = NSTextField(labelWithString: "")
    private let size = NSPopUpButton()
    private let matte = NSPopUpButton()
    private let words = NSButton(checkboxWithTitle: "Transcript (.words.json)", target: nil, action: nil)
    private let subtitles = NSButton(checkboxWithTitle: "Subtitles (.srt)", target: nil, action: nil)
    private let fcpxml = NSButton(checkboxWithTitle: "Final Cut Pro XML (.fcpxml)", target: nil, action: nil)
    private let reveal = NSButton(checkboxWithTitle: "Show the files in the Finder", target: nil, action: nil)
    private let codecNote = MovieExportSettings.note(), qualityNote = MovieExportSettings.note()
    private let sizeNote = MovieExportSettings.note()

    override func loadView() {
        codec.addItems(withTitles: Codec.allCases.map(\.label))
        size.addItems(withTitles: ExportSettings.sizes.map(\.label))
        matte.addItems(withTitles: Matte.allCases.map(\.label))
        quality.minValue = 0.5
        quality.maxValue = 1
        quality.numberOfTickMarks = 11
        quality.allowsTickMarkValuesOnly = true
        quality.isContinuous = true
        percent.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        percent.textColor = .secondaryLabelColor
        for c in [codec, quality, size, matte, words, subtitles, fcpxml, reveal] as [NSControl] {
            c.target = self
            c.action = #selector(changed(_:))
        }
        let slider = NSStackView(views: [sized(quality, 236, nil), percent])
        slider.spacing = 6
        let line = sized(NSBox(), 395, nil)
        line.boxType = .separator
        let also = NSStackView(views: [words, subtitles, fcpxml])
        also.orientation = .vertical
        also.alignment = .leading
        also.spacing = 6

        let grid = NSGridView(views: [
            [label("Format:"), codec], [NSGridCell.emptyContentView, codecNote],
            [label("Quality:"), slider], [NSGridCell.emptyContentView, qualityNote],
            [label("Size:"), size], [NSGridCell.emptyContentView, sizeNote],
            [label("Background:"), matte],
            [NSGridCell.emptyContentView, line],
            [label("Also Write:"), also],
            [label("After Export:"), reveal],
        ])
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        grid.rowSpacing = 5
        grid.columnSpacing = 8
        for i in [1, 3, 5, 6, 8] { grid.row(at: i).bottomPadding = 8 }
        // the line keeps its own space above and below
        grid.row(at: 7).topPadding = 6
        grid.row(at: 7).bottomPadding = 6
        grid.row(at: 7).yPlacement = .center

        let page = NSView()
        grid.translatesAutoresizingMaskIntoConstraints = false
        page.addSubview(grid)
        NSLayoutConstraint.activate([
            page.widthAnchor.constraint(equalToConstant: 560),
            grid.topAnchor.constraint(equalTo: page.topAnchor, constant: 20),
            grid.bottomAnchor.constraint(equalTo: page.bottomAnchor, constant: -20),
            grid.leadingAnchor.constraint(equalTo: page.leadingAnchor, constant: 40),
            grid.trailingAnchor.constraint(lessThanOrEqualTo: page.trailingAnchor, constant: -40),
        ])
        view = page
        show()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        preferredContentSize = view.fittingSize
    }

    private func label(_ s: String) -> NSTextField { NSTextField(labelWithString: s) }

    /// The line of explanation under a control.
    private static func note(_ s: String = "") -> NSTextField {
        let n = NSTextField(wrappingLabelWithString: s)
        n.font = .systemFont(ofSize: 12)
        n.textColor = .secondaryLabelColor
        n.preferredMaxLayoutWidth = 320
        return sized(n, 320, nil)
    }

    /// Each control as the stored settings read, with the notes that go with them.
    private func show() {
        let c = ExportSettings.codec
        codec.selectItem(at: Codec.allCases.firstIndex(of: c) ?? 0)
        codecNote.stringValue = c == .hevc ? "A small file." : "A much larger file, for a workflow that asks for ProRes."
        quality.doubleValue = ExportSettings.quality
        quality.isEnabled = c == .hevc
        percent.stringValue = "\(Int((ExportSettings.quality * 100).rounded()))%"
        qualityNote.stringValue = c == .hevc ? "Higher is cleaner, and a larger file." : "ProRes 4444 has one quality."
        let lines = ExportSettings.lines ?? 0
        size.selectItem(at: ExportSettings.sizes.firstIndex { $0.lines == lines } ?? 0)
        sizeNote.stringValue = lines == 0
            ? "Pixel for pixel over the footage."
            : "Scaled from the video's shape. Final Cut fits it to the project; a smaller movie exports sooner and looks softer."
        let m = ExportSettings.matte
        matte.selectItem(at: Matte.allCases.firstIndex(of: m) ?? 0)
        words.state = ExportSettings.words ? .on : .off
        subtitles.state = ExportSettings.subtitles ? .on : .off
        fcpxml.state = ExportSettings.fcpxml ? .on : .off
        reveal.state = ExportSettings.reveal ? .on : .off
    }

    @objc private func changed(_ sender: NSControl) {
        switch sender {
        case codec: d.set(Codec.allCases[codec.indexOfSelectedItem].rawValue, forKey: ExportSettings.codecKey)
        case quality: d.set((quality.doubleValue * 20).rounded() / 20, forKey: ExportSettings.qualityKey)
        case size: d.set(ExportSettings.sizes[size.indexOfSelectedItem].lines, forKey: ExportSettings.linesKey)
        case matte: d.set(Matte.allCases[matte.indexOfSelectedItem].rawValue, forKey: ExportSettings.matteKey)
        case words: d.set(words.state == .on, forKey: ExportSettings.wordsKey)
        case subtitles: d.set(subtitles.state == .on, forKey: ExportSettings.subtitlesKey)
        case fcpxml: d.set(fcpxml.state == .on, forKey: ExportSettings.fcpxmlKey)
        case reveal: d.set(reveal.state == .on, forKey: ExportSettings.revealKey)
        default: break
        }
        show()
        preferredContentSize = view.fittingSize
    }
}
