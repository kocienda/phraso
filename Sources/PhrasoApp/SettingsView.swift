import PhrasoKit
import SwiftUI

/// What the app remembers between documents. One topic so far: the movie an Export writes.
enum ExportSettings {
    static let codecKey = "exportCodec"
    static let qualityKey = "exportQuality"

    static var codec: Codec {
        UserDefaults.standard.string(forKey: codecKey).flatMap(Codec.init(rawValue:)) ?? .hevc
    }

    static var quality: Double {
        UserDefaults.standard.object(forKey: qualityKey) as? Double ?? MovieWriter.defaultQuality
    }
}

/// The Settings window (⌘,): a topic per tab.
struct SettingsView: View {
    var body: some View {
        TabView {
            MovieExportSettings()
                .tabItem { Label("Movie Export", systemImage: "film") }
        }
        .frame(width: 520)
    }
}

/// The caption movie's format. Its size and frame rate are always the video's own, so
/// the track drops onto the timeline without a conform.
struct MovieExportSettings: View {
    @AppStorage(ExportSettings.codecKey) private var codec = Codec.hevc
    @AppStorage(ExportSettings.qualityKey) private var quality = MovieWriter.defaultQuality

    var body: some View {
        Form {
            Picker("Format:", selection: $codec) {
                ForEach(Codec.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .fixedSize()
            Text(codec == .hevc
                 ? "A small file."
                 : "A much larger file, for a workflow that asks for ProRes.")
                .font(.callout).foregroundStyle(.secondary)
                .frame(width: 320, alignment: .leading)
                .padding(.bottom, 8)

            Slider(value: $quality, in: 0.5...1, step: 0.05) {
                Text("Quality:")
            } minimumValueLabel: {
                Text("")
            } maximumValueLabel: {
                Text("\(Int((quality * 100).rounded()))%").monospacedDigit()
            }
            .frame(width: 320)
            .disabled(codec != .hevc)
            Text(codec == .hevc
                 ? "Higher is cleaner, and a larger file."
                 : "ProRes 4444 has one quality.")
                .font(.callout).foregroundStyle(.secondary)
                .frame(width: 320, alignment: .leading)

            LabeledContent("Size:") { Text("Same as the video").foregroundStyle(.secondary) }
                .padding(.top, 8)
            LabeledContent("Frame Rate:") { Text("Same as the video").foregroundStyle(.secondary) }
        }
        .padding(.horizontal, 40).padding(.vertical, 20)
    }
}
