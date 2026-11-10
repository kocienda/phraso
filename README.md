# Phraso

Word-highlighted captions for video, made on the Mac. A video goes in; a caption movie
comes out: the captions alone over an alpha channel, at the video's own frame rate, to
lay over the footage as a single clip. The spoken word is coloured and pops in, the way
the trending caption presets do, in any font, with rounded nested borders, a box and a
shadow.

It is made for Final Cut Pro, where the movie is dragged onto the timeline above the clip
it captions and connects there, but the movie is an ordinary QuickTime file: any editor
that reads alpha takes it as it is, and one that does not can have the cards on a solid
colour instead.

Nothing leaves the machine. Speech recognition is the Mac's own (the Speech framework),
the cards are drawn with Core Text and Core Graphics, and the movie is written with
AVFoundation. It needs macOS 26.

## What it makes

From one video or sound file, beside it unless told otherwise:

- **The caption movie** (`talk.captions.mov`): HEVC with alpha, or Apple ProRes 4444.
  Steps fall on whole frames of the footage, so every word changes on a frame of the video.
- **The transcript** (`talk.captions.words.json`): every word with its timing, to correct
  by hand and give back, with the timings kept.
- **Subtitles**, if asked for (`talk.captions.srt`): SubRip, one cue per card.
- **A Final Cut project**, if asked for (`talk.captions.fcpxml`): the movie over a gap, to
  import. It is off by default, since an import leaves an event and a project behind,
  and dragging the movie onto the timeline does the same job.

## The app

A document is one video and its captions. A new document asks for its video (any movie or
sound file AVFoundation opens, or drop one on the window), transcribes it on the Mac and
shows:

- **The preview**: the footage playing with the caption drawn over it, a scrubber and the
  transport, on Space, ←, →, Home and End.
- **The transcript**: every word as an editable chip. Click a word to move the playhead
  to it and fix it; Tab and Shift-Tab go between words; edits are undo steps.
  Re-transcribe starts over.
- **The styles**: the presets as thumbnails, and an inspector, laid out like Keynote's,
  for every field of the style: font, letter case, tracking, colours, the spoken word's
  scale, up to three nested borders, shadow, box, pop-in, position, rotation and flips,
  and how words are grouped into cards. File > Save Style as Preset (⇧⌘S) keeps the look.
- **Export** (⌘E): writes the movie and whatever Settings > Movie Export asks for beside
  it. The movie then sits as a chip above the transcript, and on the film icon in the
  title bar, to drag from there onto the Final Cut timeline.

A document saves as a `.phraso` package holding the corrected words, the style, the
playhead and a bookmark to the video, which stays where it is. Untitled documents are
kept too and come back at the next launch.

Settings > Movie Export (⌘,) chooses the format and quality, the size, the background,
which files go beside the movie, and whether the Finder shows them after an Export.

Build it with `Scripts/bundle-app.sh && open Phraso.app`, or open `Phraso.xcodeproj`.

## The command

```sh
swift build -c release
.build/release/phraso make talk.mov --style area
```

writes `talk.captions.mov` and `talk.captions.words.json` beside the video. In Final Cut,
park the playhead on the first frame of the clip the captions belong to and drag the
movie onto the timeline above it; it connects there, and Final Cut files it in the
project's own event. Put the movie where it will stay first: Final Cut links it in place.

To fix a word, edit `talk.captions.words.json` and run again with
`--words talk.captions.words.json`; the timings hold.

The options of `make`:

| Option | What it does |
|---|---|
| `--style area` | a preset name, or a path to a style `.json` |
| `--out dir`, `--name N` | where the files go, and what they are called |
| `--words words.json` | use this transcript instead of transcribing |
| `--locale en-US` | the language to transcribe |
| `--codec hevc\|prores` | HEVC with alpha (the default) or ProRes 4444 |
| `--quality 0.9` | HEVC quality, `0.5` to `1` |
| `--size 1080` | scale the movie to that many pixels on its shorter side; the video's own size otherwise |
| `--matte clear\|black\|green\|blue` | a solid colour behind the cards, for an editor that does not read alpha |
| `--srt` | also write SubRip subtitles |
| `--fcpxml` | also write a Final Cut project holding the movie over a gap |
| `--background gap\|grey` | what the project puts under the movie; `grey` implies `--fcpxml` |

The rest:

```sh
phraso transcribe talk.mov --out talk.words.json       # the words alone
phraso preview talk.mov --style glanceable --time 6.5  # one frame, over grey, to look at
phraso styles                                          # the presets, shipped and yours
phraso style area --out mine.json                      # a preset to edit; then --style mine.json
phraso icon --text Hi! --out icon.png                  # the app icon, a word in a style
```

## Styles

A style is one JSON file; the format is documented at the top of
`Sources/PhrasoKit/Style.swift`. Five ship with it: `area`, `boxed`, `clean`,
`glanceable` and `yellow`. Every preset is a file in
`~/Library/Application Support/Phraso/Presets/`; the shipped ones are copied there the
first time they are missing, so they can be edited or deleted like your own, and the app
and the command read the same folder.

## Layout

- `Sources/PhrasoKit` — the engine: `Transcript` (speech to timed words), `Cards`
  (words into cards and steps), `Style` (the preset format), `Renderer` (one card),
  `MovieWriter` (every frame into HEVC-with-alpha or ProRes 4444), `Subtitles` (SubRip),
  `FCPXML`, `Job` (video in, files out), `Timing` (rational frame rates from the video).
- `Sources/phraso` — the command.
- `Sources/PhrasoApp` — the app, in AppKit: an `NSDocument`, its window controller, a menu
  bar built in code, and views laid out in code. `Phraso.xcodeproj` builds it as an app
  target over the package; `Scripts/bundle-app.sh` does the same with SwiftPM alone. Both use
  `App/Info.plist` and `App/AppIcon.icns` (drawn by `Scripts/make-icon.sh`).
- `Tests/PhrasoKitTests` — cards, styles, rendering, the movie, subtitles, the FCPXML.
- `Tools/fcp.py` — drives Final Cut through System Events and screen capture to import
  a file and photograph the viewer at timecodes, so the output is checked by machine.
  `Tools/fcp/` holds the small Swift helpers it and the app checks use (window ids,
  mouse clicks); `Tools/nibdump.py` reads Keynote's inspector nibs for the inspector's
  measurements.
