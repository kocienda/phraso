# Phraseo

A Mac app and command that make CapCut-style word-highlighted captions for Final Cut
Pro: on-device transcription, cards drawn with Core Text, one HEVC-with-alpha movie,
FCPXML placing it as a single connected clip. Grew out of `/u/vids/tools/captions.py`;
that repo keeps the record of what Final Cut's own title tools cannot do
(`/u/vids/docs/captions.md`). This repo is the product.

## Layout

See `README.md`. Engine in `Sources/PhraseoKit`, command in `Sources/phraseo`, app in
`Sources/PhraseoApp`, tests in `Tests/PhraseoKitTests`, Final Cut harness in `Tools/`.

## Rules

- The style file is a published format (`Style.swift` header). A new field gets a
  default, so every existing preset still loads; a breaking change bumps `phraseo`.
- Units in a style are a 1920×1080 canvas; the renderer scales by height.
- Every line sits on the same baseline: the renderer anchors on the font's cap height,
  never on glyph bounds. A change that moves text vertically for one card and not
  another is a bug.
- Steps abut on whole frames. Times in FCPXML are frames × num/den of the video's own
  frame rate (`FrameRate`), never decimal seconds.
- Keep PhraseoKit free of AppKit UI: the command and the app both sit on it.

## Verifying

Fast, after every edit:

```sh
swift build && swift test
.build/debug/phraseo preview /u/vids/incoming/one-graphical-language.words.json --style area --step 19 --out /tmp/card.png
```

Slow, once per change to the output:

```sh
.build/debug/phraseo make /u/vids/incoming/one-graphical-language.wav --words /u/vids/incoming/one-graphical-language.words.json --out /tmp/ph --name ogl --background grey
python3 Tools/fcp.py check /tmp/ph/ogl.fcpxml 00:00:06:16 00:00:06:19 00:00:07:05 --out /tmp/frames.png
```

imports the file into Final Cut, opens the project and tiles viewer crops into one PNG.
Needs Accessibility and Screen Recording for the host app and Final Cut's default
layout. Each import adds an event, so test files get distinct `--name`s. Never ask the
user to click through a check this can run.

The app: `Scripts/bundle-app.sh --debug` makes `Phraseo.app`; launch it with
`open Phraseo.app --env PHRASEO_VIDEO=talk.mov` (a bare path argument is taken as a
document to open and no window appears). `build/winid Phraseo` (from
`Tools/fcp/winid.swift`) lists its windows for `screencapture -l`. The Xcode project
must keep building too: `xcodebuild -project Phraseo.xcodeproj -scheme Phraseo build`.
A new source file in `Sources/PhraseoApp` goes into the project as well.
