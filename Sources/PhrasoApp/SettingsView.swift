import PhrasoKit
import SwiftUI

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

/// The Settings window (⌘,): a topic per tab.
struct SettingsView: View {
    var body: some View {
        TabView {
            MovieExportSettings()
                .tabItem { Label("Movie Export", systemImage: "film") }
        }
        .frame(width: 560)
    }
}

/// What an Export writes: the caption movie's format, size and background, and the
/// files that go beside it. Its frame rate is always the video's own, so every word
/// changes on a frame of the footage.
struct MovieExportSettings: View {
    @AppStorage(ExportSettings.codecKey) private var codec = Codec.hevc
    @AppStorage(ExportSettings.qualityKey) private var quality = MovieWriter.defaultQuality
    @AppStorage(ExportSettings.linesKey) private var lines = 0
    @AppStorage(ExportSettings.matteKey) private var matte = Matte.clear
    @AppStorage(ExportSettings.wordsKey) private var words = true
    @AppStorage(ExportSettings.subtitlesKey) private var subtitles = false
    @AppStorage(ExportSettings.fcpxmlKey) private var fcpxml = false
    @AppStorage(ExportSettings.revealKey) private var reveal = true

    var body: some View {
        Form {
            Picker("Format:", selection: $codec) {
                ForEach(Codec.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .fixedSize()
            note(codec == .hevc
                 ? "A small file."
                 : "A much larger file, for a workflow that asks for ProRes.")

            Slider(value: $quality, in: 0.5...1, step: 0.05) {
                Text("Quality:")
            } minimumValueLabel: {
                Text("")
            } maximumValueLabel: {
                Text("\(Int((quality * 100).rounded()))%").monospacedDigit()
            }
            .frame(width: 320)
            .disabled(codec != .hevc)
            note(codec == .hevc
                 ? "Higher is cleaner, and a larger file."
                 : "ProRes 4444 has one quality.")

            Picker("Size:", selection: $lines) {
                ForEach(ExportSettings.sizes, id: \.lines) { Text($0.label).tag($0.lines) }
            }
            .fixedSize()
            note(lines == 0
                 ? "Pixel for pixel over the footage."
                 : "Scaled from the video's shape. Final Cut fits it to the project; a smaller movie exports sooner and looks softer.")

            LabeledContent("Frame Rate:") { Text("Same as the video").foregroundStyle(.secondary) }
            note("So every word changes on a frame of the footage.")

            Picker("Background:", selection: $matte) {
                ForEach(Matte.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .fixedSize()
            note(matte == .clear
                 ? "The cards over an alpha channel, which Final Cut reads as it is."
                 : "A solid colour behind the cards, for an editor or a site that does not read alpha.")

            Divider().padding(.vertical, 6)

            LabeledContent("Also Write:") {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("Transcript (.words.json)", isOn: $words)
                    Toggle("Subtitles (.srt)", isOn: $subtitles)
                    Toggle("Final Cut Pro XML (.fcpxml)", isOn: $fcpxml)
                }
            }
            note("The transcript can be corrected and given back to the phraso command. The XML is a project holding the movie, to import.")

            LabeledContent("After Export:") {
                Toggle("Show the files in the Finder", isOn: $reveal)
            }
        }
        .padding(.horizontal, 40).padding(.vertical, 20)
    }

    /// The line of explanation under a control.
    private func note(_ s: String) -> some View {
        Text(s)
            .font(.callout).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(width: 320, alignment: .leading)
            .padding(.bottom, 8)
    }
}
