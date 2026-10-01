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
3. The transcript, as one continuous text in the system font. It can be selected
   across speakers, searched with ⌘F, and clicked: a click on a word moves the
   playhead there. The word being played is marked. Space does not play: the
   transcript is text, and Space belongs to text. ⌘Return plays and pauses from the
   playhead, and so do the play button and the keyboard's Play/Pause key. Clicking a speaker's name on a line opens the menu that
   reassigns the line; "Split here" cuts the line at the clicked word.
   A misheard word is corrected in place by typing over it, as in any document.
4. A playback bar along the bottom: play, back 15 seconds, the time, a strip showing
   who spoke when, and speed.

Copy as Markdown is a toolbar button; saving to a file stays in an Export menu.

**While recording**, the page shows the clock, the ribbon, Pause and Stop. The live
transcript is behind a "Show transcript" control, off by default.

### Slices

Each one ends with something that runs. The uncertain ones went first.

| # | Slice | State on 2026-10-01 |
|---|---|---|
| 1 | The transcript as one text view: selectable across speakers, ⌘F, speaker names clickable, split at the clicked word, a click moving the playhead. | Installed. Seen working on screen, except splitting a line. |
| 2 | Word timings kept for new recordings and imports; the click lands on the exact word, and the word being played is marked. | Installed. The matching passed six sample cases. Not yet seen on a real recording. |
| 3 | Correcting words by typing over them. | Installed. Passed an off-screen test: a word typed over, text added at the start of a line, and two forbidden edits refused. Not yet typed in the real window. |
| 4 | Layout A: speaker chips and the summary at the top, no side column, a playback bar with a strip of who spoke when, skip and speed, Copy as Markdown. | Installed. The page, the chips and their editor, the folded summary and the bar were seen on screen. Playing, skip, speed and dragging the strip are untried. |
| 5 | The list: New Meeting, Import and Delete above it, selecting several, search that shows and lands on the sentence. Import folded in, keeping audio and the file's own date. | Installed. The bar was seen on screen. Selecting several, deleting, importing and search are untried. |
| 6 | The quiet live page. | Installed. Untried: it needs a meeting. |

The list's commands are in a bar inside the list's column. The window toolbar was
tried first and pushed Import and Delete into an overflow menu at the far side.

All six are on the branch `meetings-rework`, not merged.

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
  a space, so it cannot also be the key that plays. Call, on Jonathan's word: Space
  is left to the text. ⌘Return, the play button and the keyboard's Play/Pause key
  play and pause.
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
