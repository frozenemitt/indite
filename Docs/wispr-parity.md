# Matching Wispr Flow

Shaped 2026-11-08 from the Wispr Flow teardown
(https://claude.ai/artifact/2VUAMn9NJT6X5y1GFRyEAx). Jonathan approved fourteen of its
fifteen proposals and declined more languages, which he will not use. His four comments
on the report are listed at the end until he decides on them.

## Problem

Indite already matches Wispr Flow's dictation loop, and it keeps everything on the Mac.
Wispr Flow is still better in four ways that show up every day.

- **The wait.** Indite's AI pass takes 0.47 to 1.75 s after the key is released,
  because the model types the whole dictation out again. In 73 of Jonathan's last 100
  dictations it changed nothing. Wispr Flow pastes in 0.23 to 0.39 s.
- **Layout.** Wispr Flow turns counted items into a list, gives a greeting and a
  sign-off lines of their own, writes digits and drops a phrase the speaker took back,
  all without rewording. Indite's Clean Up does these things but rewrites the voice,
  and Simple Clean Better does none of them.
- **Selected text.** Wispr Flow runs the user's own prompt on a selection, by key or by
  voice. Indite leaves that to Apple's Writing Tools, which offers only stock tones.
- **The edges.** Wispr Flow says when secure input blocks the key, mutes the Mac during
  a dictation, falls back down a list of microphones, sends a message on "press enter",
  keeps snippets exact, sounds when the recording locks, starts from a mouse button,
  counts words, hides its panel from screen sharing, and names meeting speakers from
  the calendar. Indite does none of these.

## Solution sketch

Eighteen slices, each shipped and installed on its own. The uncertain ones go first, so
that what is left at the end is polish.

**The AI pass answers with its corrections.** For a prompt that keeps the speaker's
words, the model replies with a short list of changes, one per line in the form
`old words → new words`, or with `NONE`. Indite applies each change where its old words
appear in the transcript, drops any change whose old words do not, and runs the word
check on the result as it does today. The answer shrinks from the length of the
dictation to a few words, so the wait should stay near the model's start-up of 0.35 to
0.56 s whatever the length. The answer stays plain text: Apple screens a structured
answer as strictly as its default guardrails, which refused 3 of 34 dictations on
2026-10-11.

**A layout level that keeps the words.** Rules handle what rules can. Counted items
("one… two… three…", "first… second…") become a list, a greeting and a sign-off get
lines of their own, and spoken numbers become digits where they count something. The
model handles a change of mind, and the word check is allowed to drop the words before
"no, actually", "I mean" or "make that". It ships as a built-in prompt that keeps words.

**Selected text.** A shortcut runs a chosen prompt on the selection and pastes the
rewrite over it, with undo. Indite reads the selection through accessibility and falls
back to copying it. Spoken commands follow as their own slice: with text selected, the
user says what to do with it.

**Small slices**, each one downhill unless it is marked:

- Secure input (uphill). Indite watches whether secure input is on, names the app that
  holds it, and shows that on the menu bar icon and in the panel.
- Microphone order (uphill). Settings ranks the microphones; Indite records from the
  first one present, skips the built-in one when the lid is closed, and notes that
  Bluetooth microphones start slowly and mishear more.
- A sound and a lock symbol when a double tap locks the recording.
- "Press enter" as the last words of a dictation sends it: the words are dropped, and
  Return follows the paste.
- Snippets. A spoken cue pastes saved text exactly. The cue is expanded after the AI
  pass, so the model never sees the saved text; when the model has reworded the cue,
  that dictation is pasted without the AI pass.
- Mute the Mac's sound during a dictation. Off by default; the sound comes back at the
  end, and at the next launch if Indite quit while muting.
- Hide the dictation panel from screen sharing and screenshots (uphill on macOS 27).
  Opt-in. The meeting indicator stays visible, because hiding a recording from the
  people on a call is a question of their consent.
- A mouse side button starts and stops a dictation.
- Words dictated, speaking speed in words per minute, and a streak of days, from the
  history.

**Meetings**, in five slices: speaker names and a title from the calendar event behind
a recording; a warning before a recording passes two hours; a notepad whose notes join
the summary; action items; and a few templates run on a finished meeting.

### Slices

| # | Slice | Proposal | Size | State on 2026-11-08 |
|---|---|---|---|---|
| 1 | The AI pass answers with its corrections | 2 | medium, uphill | Bench next |
| 2 | A layout level that keeps the words | 1 | medium, uphill | Not started |
| 3 | Secure input warning | 4 | small, uphill | Not started |
| 4 | Microphone order | 6 | small, uphill | Not started |
| 5 | Your prompts on selected text | 3 | medium | Not started |
| 6 | Spoken commands on a selection | 14 | large, uphill | Shaped after 5 |
| 7 | A cue when the recording locks | 9 | small | Not started |
| 8 | "Press enter" | 7 | small | Not started |
| 9 | Snippets | 8 | small | Not started |
| 10 | Mute during a dictation | 5 | small | Not started |
| 11 | Panel hidden from screen sharing | 11 | small, uphill | Not started |
| 12 | Mouse side button | 12 | small | Not started |
| 13 | Words, speed and streak | 13 | small | Not started |
| 14 | Meeting names from the calendar | 10 | medium | Not started |
| 15 | Two-hour warning | 10 | small | Not started |
| 16 | Meeting notepad | 10 | medium | Not started |
| 17 | Action items | 10 | small | Not started |
| 18 | Meeting templates | 10 | medium | Not started |

## Rabbit holes

- **The model may not keep to a list of changes.** Patch upfront: bench it on the last
  100 dictations against today's full rewrite, and ship only if the final text matches
  on at least 95 of them and the wait drops. A change whose old words do not appear in
  the transcript is dropped, never guessed at.
- **Punctuation fixes in a list of changes.** 16 of the 100 dictations changed only
  punctuation or capitals, and a change has to quote enough words around a mark to
  place it. The bench decides whether the model can.
- **A change of mind looks like a dropped word to the word check.** The layout level
  loosens the check only for the words before an explicit cue; any other missing word
  is still put back.
- **Secure input may hide the key from Indite entirely,** in which case a warning
  cannot wait for the key press. Patch upfront: the warning comes from watching secure
  input, not from the press.
- **`sharingType = .none` may not hide a window from ScreenCaptureKit.** Patch upfront:
  capture the screen with the panel up before building the setting. If the panel still
  shows, the slice is dropped.
- **Selections in apps without accessibility text,** such as Electron apps and some web
  pages. Patch upfront: copy with ⌘C and put the clipboard back.
- **A crash while muted leaves the Mac silent.** Patch upfront: store the sound's state
  and restore it at launch.
- **Calendar access means full access to events** in the privacy settings. In scope:
  Indite reads only the events that overlap a recording.
- **History does not store how long a dictation took,** so speaking speed counts from
  the first dictation after that slice ships.
- **Spoken commands need a trigger that ordinary dictation cannot set off,** because
  dictating over a selection replaces it today. That slice is shaped after slice 5.

## No-gos

- More languages (declined 2026-11-08).
- Pausing music, which needs Apple's private media framework.
- Calendar reminders, automatic start and call detection (dropped 2026-11-01).
- Anything that sends audio or text off the Mac.
- The rest of the report's skipped list: Focus Mode, badges and referrals, team
  sharing, learning a style from Gmail, and sending through Gmail, Slack or Notion.

## Awaiting Jonathan

His four comments on the report, assessed on 2026-11-08, each a proposal of its own:

- Keeping dictation audio, so a failed dictation can be retried.
- Noticing a dead microphone during the dictation, not after it.
- Shorter shortcuts, as in Wispr Flow.
- Learning words from corrections the way Wispr Flow does.
