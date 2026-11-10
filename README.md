# Phraseo

Word-highlighted captions for Final Cut Pro, made on the Mac. A video goes in; a
caption track comes out: one movie with an alpha channel and the FCPXML that drops
it onto the timeline as a single connected clip. The spoken word is coloured and pops
in, the way the trending caption presets do, in any font, with rounded nested borders,
a box, a shadow.

Nothing leaves the machine. Speech recognition is the Mac's own (the Speech
framework, macOS 26), the cards are drawn with Core Text and Core Graphics, and the
movie is written with AVFoundation.

## Use it

```sh
swift build -c release
.build/release/phraseo make talk.mov --style area
```

writes `talk.captions.mov`, `talk.captions.fcpxml` and `talk.captions.words.json`
beside the video. In Final Cut: File > Import > XML, open the project it creates,
copy the connected clip, paste at the head of your edit.

To fix a word, edit `talk.captions.words.json` and run again with `--words
talk.captions.words.json`; the timings hold.

```sh
phraseo preview talk.mov --style glanceable --time 6.5   # one frame, over grey, to look at
phraseo styles                                           # the presets
phraseo style area --out mine.json                       # a preset to edit; then --style mine.json
```

The app does the same with a preview over the footage, a style inspector and an
editable transcript. It is document-based: a new document asks for its video (any
movie or sound file AVFoundation opens), and saves as a `.phraseo` package holding
the corrected words, the style and a bookmark to the video. Build it with
`Scripts/bundle-app.sh && open Phraseo.app`, or open `Phraseo.xcodeproj`.

## Styles

A style is one JSON file; the format is documented at the top of
`Sources/PhraseoKit/Style.swift`. Presets ship inside the app; yours go in
`~/Library/Application Support/Phraseo/Presets/` and appear beside them. A preset
with the same file name as a shipped one replaces it.

## Layout

- `Sources/PhraseoKit` — the engine: `Transcript` (speech to timed words), `Cards`
  (words into cards and steps), `Style` (the preset format), `Renderer` (one card),
  `MovieWriter` (every frame into HEVC-with-alpha or ProRes 4444), `FCPXML`, `Job`
  (video in, track out), `Timing` (rational frame rates from the video).
- `Sources/phraseo` — the command.
- `Sources/PhraseoApp` — the SwiftUI app. `Phraseo.xcodeproj` builds it as an app target
  over the package; `Scripts/bundle-app.sh` does the same with SwiftPM alone. Both use
  `App/Info.plist` and `App/AppIcon.icns` (drawn by `Scripts/make-icon.sh`).
- `Tests/PhraseoKitTests` — cards, styles, rendering, the movie, the FCPXML.
- `Tools/fcp.py` — drives Final Cut through System Events and screen capture to import
  a file and photograph the viewer at timecodes, so the output is checked by machine.
