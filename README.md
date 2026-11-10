# Phraso

Word-highlighted captions for Final Cut Pro, made on the Mac. A video goes in; a
caption track comes out: one movie with an alpha channel, to drag onto the timeline
as a single connected clip. The spoken word is coloured and pops
in, the way the trending caption presets do, in any font, with rounded nested borders,
a box, a shadow.

Nothing leaves the machine. Speech recognition is the Mac's own (the Speech
framework, macOS 26), the cards are drawn with Core Text and Core Graphics, and the
movie is written with AVFoundation.

## Use it

```sh
swift build -c release
.build/release/phraso make talk.mov --style area
```

writes `talk.captions.mov` and `talk.captions.words.json` beside the video. In Final
Cut, park the playhead on the first frame of the clip the captions belong to and drag
the movie onto the timeline above it; it connects there, and Final Cut files it in the
project's own event. Put the movie where it will stay first: Final Cut links it in
place.

`--fcpxml` also writes `talk.captions.fcpxml`, a project holding the movie over a gap.
Importing it leaves an event and a project to clear away, so it is off unless asked for;
it is what `Tools/fcp.py` opens to check the output.

To fix a word, edit `talk.captions.words.json` and run again with `--words
talk.captions.words.json`; the timings hold.

```sh
phraso preview talk.mov --style glanceable --time 6.5   # one frame, over grey, to look at
phraso styles                                           # the presets
phraso style area --out mine.json                       # a preset to edit; then --style mine.json
```

The app does the same with a preview over the footage, a style inspector and an
editable transcript. After an Export the movie sits as a chip above the transcript, to
drag from there onto the Final Cut timeline. It is document-based: a new document asks for its video (any
movie or sound file AVFoundation opens), and saves as a `.phraso` package holding
the corrected words, the style and a bookmark to the video. Build it with
`Scripts/bundle-app.sh && open Phraso.app`, or open `Phraso.xcodeproj`.

The movie is HEVC with alpha at quality 0.9 unless told otherwise: `--codec prores`
and `--quality 0.5` to `1` on the command, Settings > Movie Export in the app. Its
frame rate is always the video's own; its size is too unless `--size 1080` scales it
to that many pixels on its shorter side. `--matte green` (or `black`, `blue`) puts a
solid colour behind the cards for an editor that does not read alpha, and `--srt`
writes SubRip subtitles beside the movie, one per card. The app's Movie Export
settings have each of these, and which files go beside the movie.

## Styles

A style is one JSON file; the format is documented at the top of
`Sources/PhrasoKit/Style.swift`. Every preset is a file in
`~/Library/Application Support/Phraso/Presets/`; the shipped ones are copied there
the first time they are missing, so they can be edited or deleted like your own.

## Layout

- `Sources/PhrasoKit` — the engine: `Transcript` (speech to timed words), `Cards`
  (words into cards and steps), `Style` (the preset format), `Renderer` (one card),
  `MovieWriter` (every frame into HEVC-with-alpha or ProRes 4444), `FCPXML`, `Job`
  (video in, track out), `Timing` (rational frame rates from the video).
- `Sources/phraso` — the command.
- `Sources/PhrasoApp` — the app, in AppKit: an `NSDocument`, its window controller, a menu
  bar built in code, and views laid out in code. `Phraso.xcodeproj` builds it as an app
  target over the package; `Scripts/bundle-app.sh` does the same with SwiftPM alone. Both use
  `App/Info.plist` and `App/AppIcon.icns` (drawn by `Scripts/make-icon.sh`).
- `Tests/PhrasoKitTests` — cards, styles, rendering, the movie, the FCPXML.
- `Tools/fcp.py` — drives Final Cut through System Events and screen capture to import
  a file and photograph the viewer at timecodes, so the output is checked by machine.
