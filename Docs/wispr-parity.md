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
| 1 | The AI pass answers with its corrections | 2 | medium, uphill | Failed its bench; see below |
| 1a | Sentence breaks the recognizer makes at pauses | Jonathan, 2026-11-08 | medium, uphill | Committed: mends 27 of 80 cuts, joins no real end |
| 2 | A layout level that keeps the words | 1 | medium, uphill | Not started |
| 3 | Secure input warning | 4 | small, uphill | Not started |
| 4 | Microphone order | 6 | small, uphill | Installed 1.2.590 (built-in first) |
| 5 | Your prompts on selected text | 3 | medium | Not started |
| 6 | Spoken commands on a selection | 14 | large, uphill | Shaped after 5 |
| 7 | A cue when the recording locks | 9 | small | Merged; review fixes committed |
| 8 | "Press enter" | 7 | small | Merged; review fixes in progress |
| 9 | Snippets | 8 | small | Merged; review fixes in progress |
| 10 | Mute during a dictation | 5 | small | Merged; review fixes committed |
| 11 | Panel hidden from screen sharing | 11 | small | Merged; its capture test passed |
| 12 | Mouse side button | 12 | small | Merged; review fixes committed |
| 13 | Words, speed and streak | 13 | small | Merged; review fixes in progress |
| 14 | Meeting names from the calendar | 10 | medium | Not started |
| 15 | Two-hour warning | 10 | small | Not started |
| 16 | Meeting notepad | 10 | medium | Not started |
| 17 | Action items | 10 | small | Not started |
| 18 | Meeting templates | 10 | medium | Not started |

### What slice 1 found

Apple's model cannot answer with only its corrections. Asked for a list of changes, it
copied whole sentences on both sides of each line, so its answers grew longer than the
dictation. Asked for a terse list, it invented fixes ("there" became "Obsidian"). Asked
to answer NONE when nothing needed fixing, it did so in 2 to 15 of 30 runs, although
today's prompt changed nothing in 52 of 60. Asked first whether a fix was needed, it said
yes 60 times out of 60.

The bench did show where the time goes. An answer of one word comes back in about
150 ms whatever the dictation's length; writing the text out runs at about 230
characters a second. The one route left to speed is to paste the words as heard at once
and replace them when the AI's version differs. That changes how a dictation feels, so
it waits for Jonathan.

### What slice 1a is about

Jonathan, 2026-11-08: the recognizer ends a sentence at a pause and capitalizes the
next word, and the AI pass leaves the fragments. Indite's pause rule deletes a mark only
before a lowercase word, so these survive it. In his last 100 dictations the recognizer
broke 207 times before a capital; two labelers agreed on 204 of 207 that 40 of those
cut one sentence in two. Today's prompt mends 16 of those 80 cases over two runs and
joins no real break.

Committed: worked examples added to every prompt that keeps the speaker's words
(`AIProcessor.sentenceBreakNote`), and a check that puts back a full stop the model
turned into a bare comma between two sentences (`WordGuard.keepingSentenceBreaks`).
Together they mend 27 of 80 and join no real end; the note costs about 0.1 s. Rejected
on the same bench: marking breaks as pauses (joined 45 real ends), one plain sentence
of instruction (28 joined, 21 as comma splices), asking the model about one break at a
time (all one answer or all the other), and part-of-speech rules alone (10 of 40). Two
of Jonathan's three examples ("dictation. But it shouldn't", "consider that.
Punctuation is") are mended by no version.

### Fixes found on the way

- A press of the dictation key during a recording it did not start, from the menu or a
  mouse button, now ends and delivers that recording. It used to cancel it silently.
- A key let go before any audio arrived no longer plays the error sound and blames the
  microphone (twice on 2026-11-08).

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

**Installed 2026-11-09 as 1.2.590**, after a review of each feature and its fixes:
recordings with a retention the user sets and Transcribe Again; the dead-microphone
warning; word learning with Undo; the ranked microphone list; and a word-check rule that
refuses a word's negation ("inelegant" had become "elegant"). The store is at version 4.
The grammar test kit (outside the repository, in `~/Development/inscribe-bench/grammar`)
scores the installed AI step at 53 of 96 dictations exactly right, against 44 for the
week's version and 49 with no AI step.

**Decided by Jonathan later on 2026-11-08:**

- Keep each dictation's recording, with a retention the user sets: a number of days,
  or keep forever. Building as `wispr/recordings`.
- Warn during a dictation when the microphone is dead, with a sound, timed from the
  moment the microphone is confirmed to deliver sound, so slow external microphones get
  time to connect. Building as `wispr/microphone`.
- Shorter shortcuts: he never runs both apps at once, so Indite takes Control-Command-Z
  and Control-Command-V. Done (8c28180).
- Learn words from corrections the way Wispr Flow does, adding them with an Undo.
  Building as `wispr/learning`.
- Switch Simple Clean Better to greedy sampling, at the next install.
- Wanted next, awaiting his go-ahead: a grammar test set of his last 100 dictations,
  then rewriting each sentence while he talks, which measured 1.23 s down to 0.76 s at
  the median (2.48 s down to 1.13 s at the slowest) without warm-up. The Mac's grammar
  checker returns nothing when called from code, so it cannot help.

His four comments on the report, as assessed before those decisions. The report's "Your
comments" section has the evidence.

- **Keeping dictation audio**, so a dictation can be transcribed again. A lossless file
  per history entry, kept exactly as long as the entry: about 31 MB per 100 dictations.
  Open: its own switch or "Keep recent dictations", and whether it expires sooner.
- **A dead microphone noticed during the dictation.** Exact digital zeros for 1 s, where
  Wispr Flow waits 5 s; a muted microphone, zero input volume or a closed lid named at
  once. Open: switch to the next ranked microphone mid-dictation, or only warn.
- **Shorter shortcuts.** Undo to ⌃⌘Z is free. Type again to ⌃⌘V collides with Wispr
  Flow's own paste-last on his Mac. Open: which app owns ⌃⌘V.
- **Learning from corrections.** Catch the edit as Wispr Flow does (accessibility
  notifications, the text around the dictation, one judgment of the last copy when the
  watch ends) and keep Indite's own rule. Open: ask first, or add with Undo.

And one from slice 1: paste the words as heard at once and replace them when the AI's
version differs, for speed.
