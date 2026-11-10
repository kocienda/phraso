// Frame rates and the video's own geometry. Final Cut thinks in rational frame
// durations (1/30s, 1001/30000s), so the timeline does too: every time is a whole
// number of frames, written as frames × num / den seconds.

import AVFoundation
import Foundation

public struct FrameRate: Equatable, Sendable, CustomStringConvertible {
    /// Frame duration as num/den seconds.
    public var num: Int
    public var den: Int

    public init(num: Int, den: Int) { self.num = num; self.den = den }

    public var fps: Double { Double(den) / Double(num) }

    /// The nearest standard rate to a nominal frames-per-second.
    public init(nearest fps: Double) {
        let standard: [FrameRate] = [
            FrameRate(num: 1001, den: 24000), FrameRate(num: 1, den: 24), FrameRate(num: 1, den: 25),
            FrameRate(num: 1001, den: 30000), FrameRate(num: 1, den: 30), FrameRate(num: 1, den: 50),
            FrameRate(num: 1001, den: 60000), FrameRate(num: 1, den: 60),
        ]
        self = standard.min { abs($0.fps - fps) < abs($1.fps - fps) }!
    }

    public static let fps30 = FrameRate(num: 1, den: 30)

    /// A whole number of frames as FCPXML time.
    public func time(_ frames: Int) -> String {
        frames == 0 ? "0s" : "\(frames * num)/\(den)s"
    }

    public var frameDuration: String { "\(num)/\(den)s" }

    public func cmTime(_ frame: Int) -> CMTime {
        CMTime(value: CMTimeValue(frame * num), timescale: CMTimeScale(den))
    }

    /// The suffix Final Cut uses in format names: p30, p2997, p2398.
    public var formatSuffix: String {
        switch (num, den) {
        case (1001, 24000): return "p2398"
        case (1001, 30000): return "p2997"
        case (1001, 60000): return "p5994"
        default: return "p\(den / num)"
        }
    }

    public var description: String {
        num == 1 ? "\(den) fps" : String(format: "%.3f fps", fps)
    }
}

/// What the pipeline needs to know about the video it is captioning.
public struct MediaInfo: Equatable, Sendable {
    public var width: Int
    public var height: Int
    public var frameRate: FrameRate
    public var duration: Double

    public init(width: Int, height: Int, frameRate: FrameRate, duration: Double) {
        self.width = width; self.height = height; self.frameRate = frameRate; self.duration = duration
    }

    /// Read from the file. An audio-only file gets a 4K 30 fps timeline.
    public static func probe(_ url: URL) async throws -> MediaInfo {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            return MediaInfo(width: 3840, height: 2160, frameRate: .fps30, duration: duration)
        }
        let (size, transform, fps) = try await track.load(.naturalSize, .preferredTransform, .nominalFrameRate)
        let r = CGRect(origin: .zero, size: size).applying(transform)
        return MediaInfo(width: Int(abs(r.width).rounded()), height: Int(abs(r.height).rounded()),
                         frameRate: FrameRate(nearest: Double(fps)), duration: duration)
    }
}
