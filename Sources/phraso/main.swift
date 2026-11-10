// phraso: word-highlighted captions for Final Cut Pro, from the command line.
//
//   phraso make <video> [--style area] [--out dir] [--name N] [--words words.json]
//                        [--codec hevc|prores] [--quality 0.9] [--locale en-US]
//                        [--size 1080] [--matte clear|black|green|blue] [--srt] [--fcpxml] [--background gap|grey]
//       video in; <name>.mov and <name>.words.json out, beside the video. Drag the movie
//       onto the Final Cut timeline. --fcpxml also writes <name>.fcpxml, a project holding
//       the movie over a gap; --background grey puts it over grey instead and implies --fcpxml
//       --size scales the movie to that many pixels on its shorter side (the video's own
//       size otherwise); --matte fills behind the cards for an editor without alpha;
//       --srt also writes <name>.srt, one subtitle per card
//   phraso transcribe <media> [--out words.json] [--locale en-US]
//   phraso preview <video|words.json> [--style area] (--step N | --frame F | --time S) [--out card.png]
//       one card (or one timeline frame, mid-pop) on grey, to look at
//   phraso styles                      the presets, shipped and yours
//   phraso style <name> [--out f.json] a preset's JSON, to copy and edit
//   phraso icon [--out icon.png] [--size 1024] [--text Hi!] [--style area]
//       the app icon: one spoken word in a style, on the Mac icon shape
//
// A style is a preset name or a path to a .json style file.

import CoreGraphics
import Foundation
import PhrasoKit

func fail(_ m: String) -> Never { FileHandle.standardError.write((m + "\n").data(using: .utf8)!); exit(1) }
func note(_ m: String) { FileHandle.standardError.write((m + "\n").data(using: .utf8)!) }

struct Args {
    var positional: [String] = []
    var options: [String: String] = [:]
    var flags: Set<String> = []

    init(_ argv: [String], valued: Set<String>) {
        var a = argv
        while !a.isEmpty {
            let x = a.removeFirst()
            if x.hasPrefix("--") {
                let k = String(x.dropFirst(2))
                if valued.contains(k) {
                    guard !a.isEmpty else { fail("--\(k) needs a value") }
                    options[k] = a.removeFirst()
                } else { flags.insert(k) }
            } else { positional.append(x) }
        }
    }
    subscript(_ k: String) -> String? { options[k] }
}

func usage() -> Never {
    let text = try! String(contentsOfFile: #filePath, encoding: .utf8)
        .split(separator: "\n").prefix { $0.hasPrefix("//") }.map { String($0.dropFirst(2).dropFirst($0.count > 2 ? 1 : 0)) }
    print(text.joined(separator: "\n"))
    exit(2)
}

func styleArg(_ a: Args) -> Style {
    do { return try Presets.style(named: a["style"] ?? "area") } catch { fail("\(error)") }
}

func runAsync(_ body: @escaping () async throws -> Void) {
    let sem = DispatchSemaphore(value: 0)
    var failure: Error?
    Task { do { try await body() } catch { failure = error }; sem.signal() }
    sem.wait()
    if let e = failure { fail("\(e)") }
}

var argv = Array(CommandLine.arguments.dropFirst())
guard let cmd = argv.first else { usage() }
argv.removeFirst()

switch cmd {
case "make":
    let a = Args(argv, valued: ["style", "out", "name", "words", "codec", "quality", "background", "locale", "size", "matte"])
    guard let video = a.positional.first else { usage() }
    var job = Job(video: URL(fileURLWithPath: video), style: styleArg(a),
                  outputDirectory: a["out"].map { URL(fileURLWithPath: $0, isDirectory: true) },
                  name: a["name"], words: a["words"].map { URL(fileURLWithPath: $0) })
    if let c = a["codec"] { guard let cc = Codec(rawValue: c) else { fail("codec is hevc or prores") }; job.codec = cc }
    if let q = a["quality"] { guard let qq = Double(q), (0...1).contains(qq) else { fail("quality is 0 to 1") }; job.quality = qq }
    if let b = a["background"] { guard let bb = Background(rawValue: b) else { fail("background is gap or grey") }; job.background = bb }
    job.writesFCPXML = a.flags.contains("fcpxml") || a["background"] != nil
    if let s = a["size"] { guard let ss = Int(s), ss >= 16 else { fail("size is the movie's shorter side in pixels, like 1080") }; job.lines = ss }
    if let m = a["matte"] { guard let mm = Matte(rawValue: m) else { fail("matte is clear, black, green or blue") }; job.matte = mm }
    job.writesSubtitles = a.flags.contains("srt")
    if let l = a["locale"] { job.locale = l }
    runAsync {
        final class Box: @unchecked Sendable { var last: Phase? = nil }
        let seen = Box()
        let t0 = Date()
        let out = try await job.run { phase, frac in
            if phase != seen.last { note("[\(phase.rawValue)]"); seen.last = phase }
            if phase == .rendering, frac > 0, Int(frac * 20) != Int((frac - 0.001) * 20) { note("  \(Int(frac * 100))%") }
        }
        let m = out.media
        print("\(out.transcript.words.count) words -> \(out.steps.count) steps, \(out.frames) frames at \(m.frameRate), \(m.width)x\(m.height), \(Int(Date().timeIntervalSince(t0)))s")
        print(out.movie.path)
        if let x = out.fcpxml { print(x.path) }
        if let s = out.subtitles { print(s.path) }
        if let w = out.words { print(w.path) }
    }

case "transcribe":
    let a = Args(argv, valued: ["out", "locale"])
    guard let media = a.positional.first else { usage() }
    runAsync {
        let t = try await Transcriber.transcribe(URL(fileURLWithPath: media), locale: a["locale"] ?? "en-US") { note($0) }
        if let o = a["out"] {
            try t.write(to: URL(fileURLWithPath: o)); note("\(t.words.count) words -> \(o)")
        } else {
            let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            print(String(data: try enc.encode(t), encoding: .utf8)!)
        }
    }

case "preview":
    let a = Args(argv, valued: ["style", "step", "frame", "time", "out", "size", "fps"])
    guard let input = a.positional.first else { usage() }
    let style = styleArg(a)
    runAsync {
        let url = URL(fileURLWithPath: input)
        let transcript: Transcript
        var media: MediaInfo
        if url.pathExtension == "json" {
            transcript = try Transcript.load(url)
            media = MediaInfo(width: 3840, height: 2160, frameRate: .fps30, duration: transcript.duration)
        } else {
            media = try await MediaInfo.probe(url)
            let sidecar = url.deletingPathExtension().appendingPathExtension("captions.words.json")
            if FileManager.default.fileExists(atPath: sidecar.path) {
                transcript = try Transcript.load(sidecar); note("using \(sidecar.lastPathComponent)")
            } else {
                transcript = try await Transcriber.transcribe(url) { note($0) }
            }
        }
        if let s = a["size"] {
            let p = s.lowercased().split(separator: "x").compactMap { Int($0) }
            guard p.count == 2 else { fail("--size WxH") }
            media.width = p[0]; media.height = p[1]
        }
        if let f = a["fps"].flatMap(Double.init) { media.frameRate = FrameRate(nearest: f) }
        let (steps, frames) = Job.plan(transcript, style: style, frameRate: media.frameRate)
        let renderer = Renderer(style: style, width: media.width, height: media.height)
        let writer = MovieWriter(renderer: renderer, frameRate: media.frameRate, frames: frames)
        let image: CGImage
        let tag: String
        if let n = a["step"].flatMap(Int.init) {
            guard n < steps.count else { fail("no step \(n); there are \(steps.count)") }
            image = try renderer.image(steps[n], grey: true); tag = "step\(n)"
        } else if let f = a["frame"].flatMap(Int.init) {
            image = try writer.frame(f, of: steps, grey: true); tag = "frame\(f)"
        } else if let t = a["time"].flatMap(Double.init) {
            let f = Int((t * media.frameRate.fps).rounded())
            image = try writer.frame(f, of: steps, grey: true); tag = "frame\(f)"
        } else {
            image = try renderer.image(steps.first ?? RenderStep(words: ["PHRASO"], highlight: 0, first: 0, last: 1), grey: true); tag = "step0"
        }
        let out = URL(fileURLWithPath: a["out"] ?? "/tmp/\(url.deletingPathExtension().lastPathComponent)-\(style.name.lowercased())-\(tag).png")
        try writePNG(image, to: out)
        print(out.path)
    }

case "styles":
    for (stem, url) in Presets.files().sorted(by: { $0.key < $1.key }) {
        let s = try? Style.load(url)
        let origin = url.path.hasPrefix(Presets.userDirectory.path) ? "yours" : "shipped"
        print("\(stem.padding(toLength: 14, withPad: " ", startingAt: 0)) \(s?.font ?? "?") \(s.map { Int($0.size) } ?? 0)  \(origin)")
    }
    print("\nyour presets: \(Presets.userDirectory.path)")

case "style":
    let a = Args(argv, valued: ["out"])
    guard let name = a.positional.first else { usage() }
    let s = styleArg(Args(["--style", name], valued: ["style"]))
    let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    let data = try! enc.encode(s)
    if let o = a["out"] { try! data.write(to: URL(fileURLWithPath: o)); print(o) } else { print(String(data: data, encoding: .utf8)!) }

case "icon":
    let a = Args(argv, valued: ["out", "size", "text", "style"])
    let size = Int(a["size"] ?? "1024") ?? 1024
    var s = styleArg(a)
    s.position = [0, 0]
    s.size = 1080 * 0.46
    s.strokes = s.strokes.map { Stroke(color: $0.color, width: $0.width * 2.2) }
    s.shadow = Shadow(color: Color(r: 0, g: 0, b: 0, a: 0.55), offset: [0, -14], blur: 30)
    s.pop = nil
    let r = Renderer(style: s, width: size, height: size)
    let ctx = r.makeContext()
    // the macOS icon grid: an 824-wide rounded square on a 1024 canvas, corners 185.4
    let k = CGFloat(size) / 1024
    let plate = CGRect(x: 100 * k, y: 100 * k, width: 824 * k, height: 824 * k)
    let shape = CGPath(roundedRect: plate, cornerWidth: 185.4 * k, cornerHeight: 185.4 * k, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10 * k), blur: 20 * k, color: CGColor(gray: 0, alpha: 0.3))
    ctx.addPath(shape); ctx.setFillColor(CGColor(gray: 1, alpha: 1)); ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(shape); ctx.clip()
    let card = try! r.image(RenderStep(words: [a["text"] ?? "Hi!"], highlight: 0, first: 0, last: 0))
    ctx.draw(card, in: CGRect(x: 0, y: 0, width: size, height: size))
    ctx.restoreGState()
    let out = URL(fileURLWithPath: a["out"] ?? "icon.png")
    try! writePNG(ctx.makeImage()!, to: out)
    print(out.path)

default:
    usage()
}
