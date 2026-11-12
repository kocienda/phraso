# Phraso transcript editing

**Purpose:** The transcript's word chips don't behave like a Mac text editor. Focus stays in a chip after Return, the space bar can't reach playback, words can't be deleted or inserted, there's no way to force a card break, and each chip is too wide.

---

## Purpose {#purpose}

The user's notes (`Resources/phraso-notes.md`, in `/u/src/phraso`), as written:

- space bar should stop/start the movie/audio playback (when nothing else is selected)
- clicking on a word chip to edit it and then hitting return should *remove the focus from that chip
- esc should remove focus from any word chip
- when there is no word chip selected, and there's no other field or component that has the focus, the return key should focus the first work chip
- clicking into a word chip should *select* the entire word. second click should position the caret where I clicked
- when a whole word chip is selected, hitting the delete key should remove the word entirely.
- when I empty a word chip and then escape or return, that chip should be removed.
- Clicking in between a word should insert a word.
- I need some way to add a *break* after a word so that we go on to the next screen regardless of the Words Per Card count.
- too much empty space to the right of each work chunk.

---

## Evidence {#evidence}

**[F01] Each chip is a text field in a collection view.** In `Sources/PhrasoApp/TranscriptView.swift`, every word is a borderless `WordField` (an `NSTextField`) inside a `WordItem`. The items sit in an `NSCollectionView` laid out by `WordFlow`, which places them 4pt apart and 10pt in from the edges. A click on the space between chips lands on the collection view's background; nothing handles it today. **(verified, read from code)**

**[F02] Return and Esc leave focus in the chip.** Return ends editing through `controlTextDidEndEditing` and leaves the field as first responder. Esc (`cancelOperation` in `WordItem.control(_:textView:doCommandBy:)`) puts back the original text and selects it, and focus stays in the chip. Tab and Shift-Tab move to the next and previous word (`step`). **(verified, read from code)**

**[F03] Space is already bound to playback, but only when nothing has the keyboard.** Playback ▸ Play has `" "` as its key equivalent (`PhrasoApp.swift`, `playbackMenu()`). `Document.transportHasKeys` (`Document.swift:222`) turns the item off whenever the window's first responder is an `NSText` or an `NSControl`, and while a sheet is up. So space fails whenever something keeps focus. A chip after Return is one known case ([F02]). There may be others, such as an inspector field or popup that holds focus after launch or after a click; that part is inference, and checking the first responder in the running app would confirm it. **(partly verified)**

**[F04] Chip width is guessed from the character count.** `TranscriptView.size(of:)` returns `max(28, count × 8.5 + 14)`. The field is inset 6pt on each side. Its font is 14pt system, or semibold for the word under the playhead. The guess is wider than real text for most words, which is the empty space on the right. **(verified, read from code)**

**[F05] Cards break on word count, pauses and punctuation, never on a word's own say.** `Cards.make` (`Sources/PhrasoKit/Cards.swift`) closes a card in five cases: at the last word, when it holds `rules.words` words, at a pause longer than `gap`, after sentence punctuation, or after clause punctuation once it holds two or more words. `Word` (`Sources/PhrasoKit/Transcript.swift`) has only `text`, `start` and `end`. **(verified, read from code)**

**[F06] Transcript edits already get undo.** The document registers every change to `transcript` as an "Edit Transcript" undo step (`Document.swift:147`). `TranscriptView.show` reloads the cells whenever the word count or the word times change. So removing or inserting a word through a `Document` method gets undo and a redraw for free. The only edit method today is `setWord(_:text:)`. **(verified, read from code)**

**[F07] The words file is shared with the command.** `Transcript` is `Codable` and is the `words.json` that `phraso make --words` reads. A change to `Word` is a change to a file format the command consumes. **(verified, read from code)**

---

## Decisions {#decisions}

**[B01] Return and Esc both save the edit and take focus off the chip.** Each one commits the text and sets the window's first responder to nil. This is a deliberate break from the Mac convention that Esc cancels: the user's note that an emptied chip is removed on Esc only works if Esc saves. Cmd-Z is how a word gets put back. With focus gone, space reaches Playback ▸ Play again ([F03]).

**[B02] Return with nothing focused focuses the first word chip, with its word selected.** "Nothing focused" means no field or control has the keyboard. The key is handled in the window's responder chain (the window controller) so it never takes Return from a control. The user chose the first word over the word under the playhead.

**[B03] Space plays and pauses only when nothing else has the keyboard, under the existing `transportHasKeys` rule.** The work is to find and remove whatever still holds focus when it shouldn't ([F03]), checked in the running app. The rule stays as it is.

**[B04] The first click on a chip selects the whole word; a click in a chip that is already being edited places the caret.** `WordField` takes `mouseDown`. When not editing, it becomes first responder and selects all, without passing the click to the field editor. When editing, it passes the click through. The first click still moves the playhead to the word, as it does now.

**[B05] Delete with the whole word selected removes the word, and focus moves to the next word, selected.** That makes deleting several words in a row a matter of pressing Delete several times. This goes through a new `Document.removeWord(_:)`, which gets undo and a redraw for free ([F06]).

**[B06] A chip left empty is removed when editing ends**, whether by Return, Esc ([B01]) or clicking away.

**[B07] Clicking the gap between two chips inserts an empty chip there, focused.** Chip spacing goes from 4pt to about 8pt so the gap can be hit, and hovering over a gap shows an insertion bar. The new word takes the pause between its neighbours if there is one. If they abut, it takes the second half of the previous word's time. Insertion goes through a new `Document.insertWord(at:)` ([F06]). Times stay inside the neighbours' span, so no other word moves.

**[B08] A word can carry a card break: Shift-Return in a chip toggles it.** `Word` gains a `break` flag. It is decoded with `decodeIfPresent`, defaulting to false, and written only when it's true, so every existing `words.json` still loads and unchanged files stay byte-for-byte the same ([F07]). `Cards.make` closes the card after a word with the flag, whatever the word count. The command honours it too, since it reads the same file. A chip with a break shows a small ⏎ mark at its right edge. The user chose Shift-Return.

**[B09] Chip width is measured, not guessed.** The width is the text measured in the semibold weight (so the word under the playhead doesn't clip when it turns bold), plus the 6 + 6pt insets, plus a couple of points for the caret. That replaces the guess in [F04], and the room it saves pays for the wider gaps in [B07].

---

## Non-goals {#non-goals}

- **A separate break chip in the transcript.** This was considered for [B08]: a break you insert and delete like a word. It is easier to see, but it adds a second kind of item to the transcript and to the words file. The user chose Shift-Return and a flag on the word.
- **Esc as cancel.** Rejected in [B01]. Undo is the way back.
- **Splitting a chip on a typed space into two words.** Raised in the sketch as an extra; it isn't in the user's notes and isn't part of this work.
- **The settings copy note** ("need to fix copy in the app settings" in `phraso-notes.md`). It is separate from this round.

---

## Exit {#exit}

An arc in `/u/src/phraso`. The work falls into these pieces:

1. **Focus and keys:** [B01], [B02], [B03]. Removing focus from the chip is what lets space work, so the space-bar check ([B03]) comes after it.
2. **Click and selection:** [B04].
3. **Delete and empty-chip removal:** [B05], [B06], with `Document.removeWord`.
4. **Insert between chips:** [B07], with `Document.insertWord` and the wider spacing. The spacing should land with or after [B09].
5. **Card break:** [B08]. The model change and the `Cards.make` change come first, with a PhrasoKit test that a break closes a card early and that a file without the flag decodes unchanged. The Shift-Return gesture and the ⏎ mark come after.
6. **Chip width:** [B09].

Each piece is checked in the running app (`Scripts/bundle-app.sh --debug`, driven with `build/click`) as well as with `swift build && swift test`. `xcodebuild -project Phraso.xcodeproj -scheme Phraso build` must keep passing too.
