// The FCPXML that brings the caption movie into Final Cut: an event holding a project
// whose spine is one gap (or a grey generator, for checking a look) with the movie
// connected above it at offset 0. Import it, open the project, copy the connected
// clip, paste at the head of the real edit.

import Foundation

public enum Background: String, CaseIterable, Sendable {
    case gap, grey
}

public enum FCPXML {
    static let greyUID = ".../Generators.localized/Solids.localized/Grey Scale.localized/Grey Scale.motn"

    static func attr(_ s: String) -> String {
        var out = "\""
        for c in s {
            switch c {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            default: out.append(c)
            }
        }
        return out + "\""
    }

    /// The document. `frames` is the length of the timeline and of the movie.
    public static func document(name: String, movie: URL, frames: Int, frameRate fr: FrameRate,
                                width: Int, height: Int, background: Background = .gap) -> String {
        let total = fr.time(frames)
        let fmt = "FFVideoFormat\(width)x\(height)\(fr.formatSuffix)"
        var resources = [
            "<format id=\"r1\" name=\(attr(fmt)) frameDuration=\"\(fr.frameDuration)\" width=\"\(width)\" height=\"\(height)\" colorSpace=\"1-1-1 (Rec. 709)\"/>",
            "<asset id=\"r2\" name=\(attr(name)) start=\"0s\" duration=\"\(total)\" hasVideo=\"1\" format=\"r1\" videoSources=\"1\">"
                + "<media-rep kind=\"original-media\" src=\(attr(movie.standardizedFileURL.absoluteString))/></asset>",
        ]
        let clip = "<video ref=\"r2\" lane=\"1\" offset=\"0s\" name=\(attr(name)) start=\"0s\" duration=\"\(total)\"/>"
        let open: String, close: String
        switch background {
        case .grey:
            resources.append("<effect id=\"r3\" name=\"Grey Scale\" uid=\(attr(greyUID))/>")
            open = "<video ref=\"r3\" name=\"Grey Scale\" offset=\"0s\" start=\"0s\" duration=\"\(total)\">"; close = "</video>"
        case .gap:
            open = "<gap name=\"Gap\" offset=\"0s\" start=\"0s\" duration=\"\(total)\">"; close = "</gap>"
        }
        return [
            "<?xml version=\"1.0\" encoding=\"UTF-8\"?>",
            "<!DOCTYPE fcpxml>",
            "<fcpxml version=\"1.9\">",
            "<resources>",
        ] .joined(separator: "\n") + "\n" + resources.joined(separator: "\n") + "\n" + [
            "</resources>",
            "<library>",
            "<event name=\(attr(name))>",
            "<project name=\(attr(name))>",
            "<sequence format=\"r1\" duration=\"\(total)\" tcStart=\"0s\" tcFormat=\"NDF\" audioLayout=\"stereo\" audioRate=\"48k\">",
            "<spine>",
            open,
            clip,
            close,
            "</spine>",
            "</sequence>",
            "</project>",
            "</event>",
            "</library>",
            "</fcpxml>",
            "",
        ].joined(separator: "\n")
    }
}
