# Meetings window rework

Slice 7 of the interface overhaul (`Docs/interface-overhaul.md`). Shaped 2026-10-01.
Jonathan chose layout A, "one page": the summary at the top of the meeting, the
transcript directly below, no right-hand column.

## Problem

A finished meeting is hard to work with in four ways.

- **The text is inert.** Clicking a line plays it, so nothing can be selected, and one
  sentence cannot be copied. Search finds the meeting and not the place in it. A
  misheard word cannot be corrected.
- **Playback is line by line.** There is no way to play a meeting through, to change
  speed, or to start from a word.
- **The commands are far from what they act on.** Delete sits at the far right of the
  window, away from the list it deletes from, and takes one meeting at a time.
- **The summary sits in a narrow side column** in small type, though it is the first
  thing wanted once a meeting has ended.

While a meeting records, the window shows a live transcript that Jonathan finds
distracting, and importing a recording has a window of its own.

## Solution sketch

The window is a list and a page.

**The list.** Its toolbar, directly above it, holds New Meeting, Import (the + button)
and Delete. Several meetings can be selected at once, and Delete, the Delete key and
the right-click menu act on all of them after one confirmation. A file dropped on the
list is imported. A search result shows the matching sentence in its row and opens on
that sentence.

**The page**, top to bottom:

1. The title, the date and length, and the speakers as chips. Clicking a chip renames
   that speaker everywhere.
2. The summary, folded to its first three points, with Regenerate.
3. The transcript, as one continuous text in the system serif. It can be selected
   across speakers, searched with ⌘F, and clicked: a click on a word moves the
   playhead there. Space plays from the selection or the playhead. The word being
   played is marked. Clicking a speaker's name on a line opens the menu that
   reassigns the line; "Split here" cuts the line at the clicked word.
   A misheard word is corrected in place: select it, press Return, type over it, and
   press Return again, as a file is renamed in Finder. Outside a correction the text
   is not editable, so Space always means play.
4. A playback bar along the bottom: play, back 15 seconds, the time, a strip showing
   who spoke when, and speed.

Copy as Markdown is a toolbar button; saving to a file stays in an Export menu.

**While recording**, the page shows the clock, the ribbon, Pause and Stop. The live
transcript is behind a "Show transcript" control, off by default.

### Slices

Each one ends with something that runs. The uncertain one goes first.

| # | Slice | Uphill or downhill |
|---|---|---|
| 1 | The transcript as one text view: selectable across speakers, serif, ⌘F, speaker names clickable, split at the clicked word. A click moves the playhead, estimated inside the line. The rest of the window stays as it is. | Uphill: this is an AppKit text view inside a SwiftUI window, and the speaker menu has to live inside it. |
| 2 | Word timings kept for new recordings and imports. The click lands on the exact word, and the word being played is marked. | Uphill until the first recording confirms the recognizer times single words. |
| 3 | Correcting words in place. Added 2026-10-01 at Jonathan's request; it was a no-go in the first shape. | Uphill: the corrected text has to stay matched to the audio, and to the search. |
| 4 | Layout A: the side column goes; summary block and speaker chips at the top; the playback bar with speed, skip and the speaker strip; Copy as Markdown. | Downhill. |
| 5 | The list: New Meeting, Import and Delete above it; selecting several; search that lands on the sentence. The Import window is deleted. Imports keep their audio and their own date. | Downhill. |
| 6 | The quiet live page. | Downhill. |

## Rabbit holes

- **Selecting text and knowing which word was clicked.** SwiftUI's `Text` can do the
  first and not the second, and its rich `TextEditor` is an editor with no read-only
  mode. Call: one `NSTextView`, not editable, for the whole transcript. It brings the
  system find bar with it, so search inside a transcript needs no interface of its own.
- **Where word timings are kept.** Putting them in the store means a new schema
  version, and a schema change has cost a recorded meeting in this project before.
  Call: a file beside the recording, written when the meeting ends and deleted with
  it. The timings are useless without the audio, so they live and die together, and
  the store's shape does not change.
- **The text on screen is not the text the recognizer timed.** Vocabulary spelling and
  word replacements change words after timing ("type script" becomes "TypeScript").
  Call: match the displayed words to the timed words in order, and give a changed word
  the time of the words it replaced.
- **A corrected word and the Space key.** In text that can be typed into, Space types
  a space, and it is also the key that plays. Call: the transcript is read-only until
  a correction is begun with Return on a selection, and read-only again once Return
  commits it or Escape abandons it. One line is open to correction at a time.
- **A correction has to reach everything that reads the meeting.** The list's search
  reads a second copy of the transcript kept without speakers. Call: search reads the
  speakers' lines where a meeting has them, so there is one text to correct.
- **Meetings recorded before this have no word timings.** Call: estimate the position
  inside the line from the word's place in it. Out of scope: running the recognizer
  over old recordings again to time them exactly.
- **Two tracks.** On a call, the microphone and the call are timed separately and
  overlap. Each timed word carries its track, and a line looks only at its own. To
  confirm on a real call; it cannot be simulated.
- **Summary points that link to their moment.** Untried. Out of this pass. A separate
  trial afterwards, on Jonathan's own meetings, with the matches shown side by side
  for him to judge.

## No-gos

- Offering to turn a correction into a Word Replacement for future dictations.
- A structured summary (decided, to do, still open).
- "Your name" on your own voice; saving every meeting to a folder; a Mark button on
  the pill. All three were offered and none has been asked for yet.
- Recognizing a voice across meetings.
- Any change to the store's schema.
