// Every frame of the caption track into one movie with an alpha channel: HEVC with
// alpha (small) or ProRes 4444. A frame is drawn only when the picture changes; held
// frames re-append the same pixel buffer.

import AVFoundation
import Foundation
import VideoToolbox

public enum Codec: String, CaseIterable, Sendable {
    case hevc, prores
}

public enum MovieError: Error, CustomStringConvertible {
    case writer(String)
    public var description: String {
        switch self { case .writer(let m): return "movie writer: \(m)" }
    }
}

public struct MovieWriter {
    public var renderer: Renderer
    public var frameRate: FrameRate
    public var frames: Int
    public var codec: Codec

    public init(renderer: Renderer, frameRate: FrameRate, frames: Int, codec: Codec = .hevc) {
        self.renderer = renderer; self.frameRate = frameRate; self.frames = frames; self.codec = codec
    }

    /// The step showing on frame f and how many frames into it f is. Steps are in order.
    public static func step(at f: Int, in steps: [RenderStep], cursor: inout Int) -> (Int, Int)? {
        while cursor < steps.count, f >= steps[cursor].last { cursor += 1 }
        guard cursor < steps.count, f >= steps[cursor].first else { return nil }
        return (cursor, f - steps[cursor].first)
    }

    /// Frame f of the timeline as an image, for previews.
    public func frame(_ f: Int, of steps: [RenderStep], grey: Bool = false) throws -> CGImage {
        var cursor = 0
        let ctx = renderer.makeContext()
        if let (i, into) = MovieWriter.step(at: f, in: steps, cursor: &cursor) {
            try renderer.draw(steps[i], into: ctx, grey: grey, pop: renderer.popScale(frameInStep: into))
        } else if grey {
            ctx.setFillColor(CGColor(gray: 0.5, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: renderer.width, height: renderer.height))
        }
        return ctx.makeImage()!
    }

    /// Write the movie. `progress` is called with frames done out of `frames`.
    public func write(_ steps: [RenderStep], to url: URL, progress: ((Int, Int) -> Void)? = nil) throws {
        let W = renderer.width, H = renderer.height
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        var settings: [String: Any] = [AVVideoWidthKey: W, AVVideoHeightKey: H]
        switch codec {
        case .prores:
            settings[AVVideoCodecKey] = AVVideoCodecType.proRes4444
        case .hevc:
            settings[AVVideoCodecKey] = AVVideoCodecType.hevcWithAlpha
            settings[AVVideoCompressionPropertiesKey] = [
                AVVideoQualityKey: 0.9,
                kVTCompressionPropertyKey_TargetQualityForAlpha as String: 0.95,
                AVVideoAllowFrameReorderingKey: false,
            ]
        }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: W, kCVPixelBufferHeightKey as String: H,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
        ])
        writer.add(input)
        guard writer.startWriting() else { throw MovieError.writer(writer.error.map { "\($0)" } ?? "startWriting failed") }
        writer.startSession(atSourceTime: .zero)

        func buffer(_ step: RenderStep?, pop: CGFloat) throws -> CVPixelBuffer {
            var pb: CVPixelBuffer?
            guard let pool = adaptor.pixelBufferPool, CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb) == kCVReturnSuccess, let buf = pb
            else { throw MovieError.writer("no pixel buffer") }
            CVPixelBufferLockBaseAddress(buf, [])
            defer { CVPixelBufferUnlockBaseAddress(buf, []) }
            let ctx = CGContext(data: CVPixelBufferGetBaseAddress(buf), width: W, height: H, bitsPerComponent: 8,
                                bytesPerRow: CVPixelBufferGetBytesPerRow(buf), space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
            if let st = step { try renderer.draw(st, into: ctx, pop: pop) }
            else { ctx.clear(CGRect(x: 0, y: 0, width: W, height: H)) }
            return buf
        }

        var cursor = 0
        var key = (-2, -2), current: CVPixelBuffer? = nil
        for f in 0..<frames {
            let hit = MovieWriter.step(at: f, in: steps, cursor: &cursor)
            let k: (Int, Int)
            let pop: CGFloat
            if let (i, into) = hit {
                pop = renderer.popScale(frameInStep: into)
                k = (i, pop == 1 ? -1 : into)  // after the pop every frame of a step is the same picture
            } else { k = (-1, -1); pop = 1 }
            if k != key || current == nil {
                current = try buffer(hit.map { steps[$0.0] }, pop: pop)
                key = k
            }
            while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.002) }
            guard adaptor.append(current!, withPresentationTime: frameRate.cmTime(f)) else {
                throw MovieError.writer("append failed at frame \(f): \(writer.error.map { "\($0)" } ?? "?")")
            }
            if f % 30 == 0 { progress?(f, frames) }
        }
        input.markAsFinished()
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        guard writer.status == .completed else { throw MovieError.writer(writer.error.map { "\($0)" } ?? "\(writer.status)") }
        progress?(frames, frames)
    }
}
