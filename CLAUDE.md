# Phraso

A Mac app and command that make word-highlighted captions for Final Cut
Pro: on-device transcription, cards drawn with Core Text, one HEVC-with-alpha movie
to drag onto the timeline as a single connected clip. Grew out of a private script
written after finding what Final Cut's own title tools cannot do. This repo is the
product.

## Layout

See `README.md`. Engine in `Sources/PhrasoKit`, command in `Sources/phraso`, app in
`Sources/PhrasoApp`, tests in `Tests/PhrasoKitTests`, Final Cut harness in `Tools/`.

## Rules

- The style file is a published format (`Style.swift` header). A new field gets a
  default, so every existing preset still loads; a breaking change bumps `phraso`.
- Units in a style are a 1920×1080 canvas; the renderer scales by height.
- Every line sits on the same baseline: the renderer anchors on the font's cap height,
  never on glyph bounds. A change that moves text vertically for one card and not
  another is a bug.
- Steps abut on whole frames. Times in FCPXML are frames × num/den of the video's own
  frame rate (`FrameRate`), never decimal seconds.
- Keep PhrasoKit free of AppKit UI: the command and the app both sit on it.
- The inspector is laid out on Keynote's own measurements (`Pane` in
  `Sources/PhrasoApp/StyleViews.swift`), read from Keynote's inspector nibs with
  `Tools/nibdump.py`. A new control goes on that grid (270 pane, 16 margins, 24-high
  rows 9 apart, 50-wide value fields with the unit inside); when in doubt, dump the
  Keynote pane that does the same job and copy its numbers.

## Verifying

Fast, after every edit:

```sh
swift build && swift test
.build/debug/phraso preview Samples/example.words.json --style outline --step 3 --out /tmp/card.png
```

Slow, once per change to the output:

```sh
.build/debug/phraso make Samples/example.wav --words Samples/example.words.json --out /tmp/ph --name sample --background grey
python3 Tools/fcp.py check /tmp/ph/sample.fcpxml 00:00:01:00 00:00:02:15 00:00:03:20 --out /tmp/frames.png
```

imports the file into Final Cut, opens the project and tiles viewer crops into one PNG
(`--background` implies `--fcpxml`; a plain `make` writes no XML, because the product is
the movie and an import leaves an event and a project behind).
Needs Accessibility and Screen Recording for the host app and Final Cut's default
layout. Each import adds an event, so test files get distinct `--name`s. Never ask the
user to click through a check this can run.

The app: `Scripts/bundle-app.sh --debug` makes `Phraso.app`; launch it with
`open Phraso.app --env PHRASO_VIDEO=talk.mov` (a bare path argument is taken as a
document to open and no window appears). `build/winid Phraso` (from
`Tools/fcp/winid.swift`) lists its windows for `screencapture -l`. The Xcode project
must keep building too: `xcodebuild -project Phraso.xcodeproj -scheme Phraso build`.
A new source file in `Sources/PhrasoApp` goes into the project as well.

Driving the app for a check: `build/click` (from `Tools/fcp/click.swift`) posts mouse
events at screen points. The title bar only answers a click that follows a hover, so
`click move X Y`, wait a second, then `click X Y`; the rename popover shows up as a
second window in `build/winid Phraso`. Scroll bars that are always shown can be tried
without touching the system setting: `defaults write com.kocienda.phraso
AppleShowScrollBars Always`, relaunch, then `defaults delete` the key.
