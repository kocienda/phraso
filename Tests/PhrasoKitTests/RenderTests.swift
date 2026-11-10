import AVFoundation
import XCTest
@testable import PhrasoKit

final class RenderTests: XCTestCase {
    let transcript = Transcript(source: "t", duration: 3.0, locale: "en-US",
                                words: words("Tug:0.5-0.9 uses:0.9-1.4 a:1.4-1.5 collection.:1.5-1.9"))

    func testPlanCasesWordsAndCoversTheTimeline() throws {
        let (steps, frames) = Job.plan(transcript, style: try Presets.style(named: "area"), frameRate: .fps30)
        XCTAssertEqual(frames, 90)
        XCTAssertEqual(steps[0].words, ["TUG", "USES", "A"])
        XCTAssertEqual(steps[0].highlight, 0)
        XCTAssertEqual(steps.map(\.highlight), [0, 1, 2, 0])
    }

    func testBaselineHoldsWithTrailingPunctuation() throws {
        // the same word with and without a comma must land its cap height at the same rows
        let r = Renderer(style: try Presets.style(named: "area"), width: 1920, height: 1080)
        let plain = try r.image(RenderStep(words: ["GOES", "IDLE"], highlight: 0, first: 0, last: 1))
        let comma = try r.image(RenderStep(words: ["GOES", "IDLE,"], highlight: 0, first: 0, last: 1))
        XCTAssertEqual(topOpaqueRow(plain), topOpaqueRow(comma))
    }

    func testRotationAndFlipsTurnAboutThePosition() throws {
        // a half turn is the same picture as mirroring both ways, and neither moves the anchor
        var s = try Presets.style(named: "area")
        s.shadow = nil
        s.position = [0, 0]
        let step = RenderStep(words: ["GOES", "IDLE,"], highlight: 0, first: 0, last: 1)
        s.rotation = 180
        let turned = try Renderer(style: s, width: 640, height: 360).image(step)
        s.rotation = 0; s.flipH = true; s.flipV = true
        let mirrored = try Renderer(style: s, width: 640, height: 360).image(step)
        XCTAssertEqual(pixels(turned), pixels(mirrored))
        s.flipH = false; s.flipV = false
        let plain = try Renderer(style: s, width: 640, height: 360).image(step)
        XCTAssertNotEqual(pixels(plain), pixels(turned))
        XCTAssertEqual(try JSONDecoder().decode(Style.self, from: JSONEncoder().encode(s)), s)
    }

    func testHighlightedWordPopsThenSettles() throws {
        let r = Renderer(style: try Presets.style(named: "area"), width: 1920, height: 1080)
        XCTAssertEqual(r.popScale(frameInStep: 0), 0.8, accuracy: 1e-9)
        XCTAssertGreaterThan(r.popScale(frameInStep: 2), 1.0)  // the overshoot
        XCTAssertEqual(r.popScale(frameInStep: 3), 1)
        XCTAssertEqual(r.popScale(frameInStep: 99), 1)
    }

    func testMovieHasOneFramePerTimelineFrameAndAnAlphaChannel() async throws {
        let style = try Presets.style(named: "area")
        let (steps, frames) = Job.plan(transcript, style: style, frameRate: .fps30)
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("phraso-\(UUID().uuidString).mov")
        let writer = MovieWriter(renderer: Renderer(style: style, width: 1920, height: 1080), frameRate: .fps30, frames: frames)
        try writer.write(steps, to: tmp)
        let asset = AVURLAsset(url: tmp)
        let track = try await asset.loadTracks(withMediaType: .video).first!
        let duration = try await asset.load(.duration)
        let size = try await track.load(.naturalSize)
        let desc = try await track.load(.formatDescriptions).first!
        XCTAssertEqual(duration.seconds, 3.0, accuracy: 1e-6)
        XCTAssertEqual(size, CGSize(width: 1920, height: 1080))
        // HEVC with alpha is tagged hvc1 with the alpha in an auxiliary layer; the empty
        // first frame below is the proof the alpha survived
        XCTAssertEqual(CMFormatDescriptionGetMediaSubType(desc), kCMVideoCodecType_HEVC)
        let (nominalRate, segments) = try await track.load(.nominalFrameRate, .segments)
        XCTAssertEqual(nominalRate, 30, accuracy: 0.01)
        XCTAssertEqual(segments.count, 1)
        // the first frame is empty, frame 15 (0.5 s) shows the first card
        let gen = AVAssetImageGenerator(asset: asset)
        gen.requestedTimeToleranceBefore = .zero; gen.requestedTimeToleranceAfter = .zero
        let f0 = try await gen.image(at: CMTime(value: 0, timescale: 30)).image
        let f15 = try await gen.image(at: CMTime(value: 15, timescale: 30)).image
        XCTAssertNil(topOpaqueRow(f0))
        XCTAssertNotNil(topOpaqueRow(f15))
        try? FileManager.default.removeItem(at: tmp)
    }

    func testFCPXMLIsOneConnectedClipOverAGap() {
        let xml = FCPXML.document(name: "t", movie: URL(fileURLWithPath: "/tmp/t.mov"), frames: 90, frameRate: .fps30, width: 1920, height: 1080)
        XCTAssertTrue(xml.contains("<format id=\"r1\" name=\"FFVideoFormat1920x1080p30\" frameDuration=\"1/30s\""))
        XCTAssertTrue(xml.contains("<asset id=\"r2\" name=\"t\" start=\"0s\" duration=\"90/30s\""))
        XCTAssertTrue(xml.contains("src=\"file:///tmp/t.mov\""))
        XCTAssertTrue(xml.contains("<gap name=\"Gap\" offset=\"0s\" start=\"0s\" duration=\"90/30s\">\n<video ref=\"r2\" lane=\"1\" offset=\"0s\""))
        XCTAssertEqual(xml.components(separatedBy: "<video ").count - 1, 1)
        let grey = FCPXML.document(name: "t", movie: URL(fileURLWithPath: "/tmp/t.mov"), frames: 90, frameRate: .fps30, width: 1920, height: 1080, background: .grey)
        XCTAssertTrue(grey.contains("Grey Scale.motn"))
    }
}

/// The first row from the top with any opaque pixel, or nil for an empty image.
func topOpaqueRow(_ img: CGImage) -> Int? {
    return pixels(img).withUnsafeBufferPointer { px in
        let w = img.width, h = img.height
        for y in 0..<h {
            for x in 0..<w where px[(y * w + x) * 4 + 3] > 128 { return y }
        }
        return nil
    }
}

func pixels(_ img: CGImage) -> [UInt8] {
    let w = img.width, h = img.height
    var px = [UInt8](repeating: 0, count: w * h * 4)
    let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
    return px
}
