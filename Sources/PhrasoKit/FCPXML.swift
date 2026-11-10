// An FCPXML that brings the caption movie into Final Cut: an event holding a project
// whose spine is one gap (or a grey generator, for checking a look) with the movie
// connected above it at offset 0. Nobody needs it to use the movie: dragged onto the
// timeline, the movie connects where it is dropped, and an import leaves an event and
// a project behind. A job writes it only when asked (`Job.writesFCPXML`), which is how
// `Tools/fcp.py` gets a project to open and photograph.

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
                                width: Int, height: Int, movieWidth: Int? = nil, movieHeight: Int? = nil,
                                background: Background = .gap) -> String {
        let total = fr.time(frames)
        let fmt = "FFVideoFormat\(width)x\(height)\(fr.formatSuffix)"
        // a movie scaled from the video's size is an asset of its own format, which Final
        // Cut fits to the project's
        let mw = movieWidth ?? width, mh = movieHeight ?? height
        let assetFormat = (mw, mh) == (width, height) ? "r1" : "r4"
        var resources = [
            "<format id=\"r1\" name=\(attr(fmt)) frameDuration=\"\(fr.frameDuration)\" width=\"\(width)\" height=\"\(height)\" colorSpace=\"1-1-1 (Rec. 709)\"/>",
            "<asset id=\"r2\" name=\(attr(name)) start=\"0s\" duration=\"\(total)\" hasVideo=\"1\" format=\"\(assetFormat)\" videoSources=\"1\">"
                + "<media-rep kind=\"original-media\" src=\(attr(movie.standardizedFileURL.absoluteString))/></asset>",
        ]
        if assetFormat == "r4" {
            resources.insert("<format id=\"r4\" frameDuration=\"\(fr.frameDuration)\" width=\"\(mw)\" height=\"\(mh)\" colorSpace=\"1-1-1 (Rec. 709)\"/>", at: 1)
        }
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
