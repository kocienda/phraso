// A style is the look of the captions: one JSON file, the preset format.
//
// {
//   "phraso": 1,
//   "name": "Area",
//   "font": "Anton",                   PostScript name
//   "size": 96,                        on a 1920x1080 canvas, scaled to the video
//   "case": "upper",                   upper | lower | title | asis
//   "fill": "#FFFFFF",                 #RRGGBB or #RRGGBBAA
//   "highlight": "#4DF2F2",            the word being spoken
//   "highlightScale": 1.0,             the spoken word grows about its baseline
//   "tracking": 0,
//   "position": [0, -380],             from the centre of the frame, y up
//   "rotation": 0,                     degrees, counter-clockwise, about the position
//   "flipH": false, "flipV": false,   mirror the card about the position
//   "strokes": [{"color": "#000000", "width": 22}],   outermost first; width reaches outside the letter
//   "shadow": {"color": "#00000099", "offset": [0, -6], "blur": 12},
//   "box": {"color": "#000000BF", "pad": [28, 14], "radius": 18},
//   "pop": {"frames": 3, "from": 0.8},   the spoken word scales in over its first frames
//   "cards": {"words": 3, "gap": 0.6, "linger": 1.5, "hold": 0.4, "minStep": 0.1}
// }
//
// Every field but "name" and "font" has a default. Presets ship inside PhrasoKit and
// users add their own to ~/Library/Application Support/Phraso/Presets/.

import CoreGraphics
import Foundation

public struct Color: Codable, Equatable, Sendable {
    public var r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat

    public init(r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat = 1) { self.r = r; self.g = g; self.b = b; self.a = a }

    /// "#RRGGBB", "#RRGGBBAA", or "r g b [a]" in 0..1.
    public init?(_ s: String) {
        let t = s.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("#") {
            let hex = t.dropFirst()
            guard hex.count == 6 || hex.count == 8, let v = UInt64(hex, radix: 16) else { return nil }
            let shift: UInt64 = hex.count == 8 ? 24 : 16
            r = CGFloat((v >> shift) & 0xff) / 255
            g = CGFloat((v >> (shift - 8)) & 0xff) / 255
            b = CGFloat((v >> (shift - 16)) & 0xff) / 255
            a = hex.count == 8 ? CGFloat(v & 0xff) / 255 : 1
        } else {
            let parts = t.split(separator: " ").compactMap { Double($0) }
            guard parts.count == 3 || parts.count == 4 else { return nil }
            r = parts[0]; g = parts[1]; b = parts[2]; a = parts.count == 4 ? parts[3] : 1
        }
    }

    public var hex: String {
        let c = [r, g, b, a].map { Int(($0 * 255).rounded()) }
        return a == 1 ? String(format: "#%02X%02X%02X", c[0], c[1], c[2])
                      : String(format: "#%02X%02X%02X%02X", c[0], c[1], c[2], c[3])
    }

    public var cgColor: CGColor {
        CGColor(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, components: [r, g, b, a])!
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let s = try? c.decode(String.self), let col = Color(s) { self = col; return }
        if let v = try? c.decode([CGFloat].self), v.count == 3 || v.count == 4 {
            self.init(r: v[0], g: v[1], b: v[2], a: v.count == 4 ? v[3] : 1); return
        }
        throw DecodingError.dataCorruptedError(in: c, debugDescription: "a colour is \"#RRGGBB\", \"#RRGGBBAA\" or [r, g, b, a]")
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(hex)
    }

    public static let white = Color(r: 1, g: 1, b: 1)
    public static let black = Color(r: 0, g: 0, b: 0)
}

public struct Stroke: Codable, Equatable, Sendable {
    public var color: Color
    public var width: CGFloat
    public init(color: Color, width: CGFloat) { self.color = color; self.width = width }
}

public struct Shadow: Codable, Equatable, Sendable {
    public var color: Color
    public var offset: [CGFloat]
    public var blur: CGFloat
    public init(color: Color, offset: [CGFloat], blur: CGFloat) { self.color = color; self.offset = offset; self.blur = blur }
}

public struct Box: Codable, Equatable, Sendable {
    public var color: Color
    public var pad: [CGFloat]
    public var radius: CGFloat
    public init(color: Color, pad: [CGFloat], radius: CGFloat) { self.color = color; self.pad = pad; self.radius = radius }
}

public struct Pop: Codable, Equatable, Sendable {
    public var frames: Int
    public var from: CGFloat
    public init(frames: Int, from: CGFloat) { self.frames = frames; self.from = from }
}

public struct Style: Codable, Equatable, Sendable {
    public static let formatVersion = 1

    public var name: String
    public var font: String
    public var size: CGFloat = 96
    public var textCase: TextCase = .upper
    public var fill: Color = .white
    public var highlight: Color = Color("#4DF2F2")!
    public var highlightScale: CGFloat = 1
    public var tracking: CGFloat = 0
    public var position: [CGFloat] = [0, -380]
    public var rotation: CGFloat = 0
    public var flipH: Bool = false
    public var flipV: Bool = false
    public var strokes: [Stroke] = []
    public var shadow: Shadow? = nil
    public var box: Box? = nil
    public var pop: Pop? = nil
    public var cards: CardRules = CardRules()

    enum CodingKeys: String, CodingKey {
        case phraso, name, font, size, textCase = "case", fill, highlight, highlightScale, tracking,
             position, rotation, flipH, flipV, strokes, shadow, box, pop, cards
    }

    public init(name: String, font: String) { self.name = name; self.font = font }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let v = try c.decodeIfPresent(Int.self, forKey: .phraso), v > Style.formatVersion {
            throw DecodingError.dataCorruptedError(forKey: .phraso, in: c, debugDescription: "preset format \(v) is newer than this Phraso (\(Style.formatVersion))")
        }
        name = try c.decode(String.self, forKey: .name)
        font = try c.decode(String.self, forKey: .font)
        size = try c.decodeIfPresent(CGFloat.self, forKey: .size) ?? 96
        textCase = try c.decodeIfPresent(TextCase.self, forKey: .textCase) ?? .upper
        fill = try c.decodeIfPresent(Color.self, forKey: .fill) ?? .white
        highlight = try c.decodeIfPresent(Color.self, forKey: .highlight) ?? Color("#4DF2F2")!
        highlightScale = try c.decodeIfPresent(CGFloat.self, forKey: .highlightScale) ?? 1
        tracking = try c.decodeIfPresent(CGFloat.self, forKey: .tracking) ?? 0
        position = try c.decodeIfPresent([CGFloat].self, forKey: .position) ?? [0, -380]
        rotation = try c.decodeIfPresent(CGFloat.self, forKey: .rotation) ?? 0
        flipH = try c.decodeIfPresent(Bool.self, forKey: .flipH) ?? false
        flipV = try c.decodeIfPresent(Bool.self, forKey: .flipV) ?? false
        strokes = try c.decodeIfPresent([Stroke].self, forKey: .strokes) ?? []
        shadow = try c.decodeIfPresent(Shadow.self, forKey: .shadow)
        box = try c.decodeIfPresent(Box.self, forKey: .box)
        pop = try c.decodeIfPresent(Pop.self, forKey: .pop)
        cards = try c.decodeIfPresent(CardRules.self, forKey: .cards) ?? CardRules()
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(Style.formatVersion, forKey: .phraso)
        try c.encode(name, forKey: .name)
        try c.encode(font, forKey: .font)
        try c.encode(size, forKey: .size)
        try c.encode(textCase, forKey: .textCase)
        try c.encode(fill, forKey: .fill)
        try c.encode(highlight, forKey: .highlight)
        try c.encode(highlightScale, forKey: .highlightScale)
        try c.encode(tracking, forKey: .tracking)
        try c.encode(position, forKey: .position)
        if rotation != 0 { try c.encode(rotation, forKey: .rotation) }
        if flipH { try c.encode(true, forKey: .flipH) }
        if flipV { try c.encode(true, forKey: .flipV) }
        try c.encode(strokes, forKey: .strokes)
        try c.encodeIfPresent(shadow, forKey: .shadow)
        try c.encodeIfPresent(box, forKey: .box)
        try c.encodeIfPresent(pop, forKey: .pop)
        try c.encode(cards, forKey: .cards)
    }

    public static func load(_ url: URL) throws -> Style {
        try JSONDecoder().decode(Style.self, from: Data(contentsOf: url))
    }

    public func write(to url: URL) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try enc.encode(self).write(to: url)
    }
}

/// Where presets live: the user's folder. The ones shipped in PhrasoKit are copied
/// there the first time they are missing, so every preset is a file the user can open,
/// edit or delete; a shipped preset edited in place stays edited.
public enum Presets {
    public static var userDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Phraso/Presets", isDirectory: true)
    }

    public static var bundledDirectory: URL? {
        Bundle.module.url(forResource: "Presets", withExtension: nil)
    }

    /// Copy any shipped preset the user's folder lacks.
    public static func installBundled() {
        guard let dir = bundledDirectory else { return }
        let fm = FileManager.default
        try? fm.createDirectory(at: userDirectory, withIntermediateDirectories: true)
        for u in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] where u.pathExtension == "json" {
            let dest = userDirectory.appendingPathComponent(u.lastPathComponent)
            if !fm.fileExists(atPath: dest.path) { try? fm.copyItem(at: u, to: dest) }
        }
    }

    /// Preset files by their stem: the user's folder, with the shipped ones installed first.
    public static func files() -> [String: URL] {
        installBundled()
        var out: [String: URL] = [:]
        for dir in [bundledDirectory, userDirectory].compactMap({ $0 }) {
            let items = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            for u in items where u.pathExtension == "json" {
                out[u.deletingPathExtension().lastPathComponent] = u
            }
        }
        return out
    }

    /// A preset by stem, or a style file by path.
    public static func style(named name: String) throws -> Style {
        if name.hasSuffix(".json") || name.contains("/") {
            return try Style.load(URL(fileURLWithPath: name))
        }
        guard let url = files()[name] else {
            throw PresetError.notFound(name, Array(files().keys).sorted())
        }
        return try Style.load(url)
    }

    public static func all() -> [Style] {
        files().values.compactMap { try? Style.load($0) }.sorted { $0.name < $1.name }
    }
}

public enum PresetError: Error, CustomStringConvertible {
    case notFound(String, [String])
    public var description: String {
        switch self {
        case .notFound(let n, let have): return "no preset named \(n); have: \(have.joined(separator: ", "))"
        }
    }
}
