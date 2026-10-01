# Interface overhaul

Started 2026-10-01 from the interface review (thirty findings). Design decisions and
Jonathan's words on each are in `DESIGN.md`.

## Problem

Each screen works, but the app leaves the person guessing what happened, and finished
meetings are hard to find again. A dictation copied to the clipboard looks the same as
one that was typed. Every meeting is called "Meeting" plus a date. The menu is a
hand-drawn panel with four controls for one question. Settings are grouped by
mechanism. None of this is acceptable for an app meant for a wide public.

## Solution sketch

Slices, each shippable on its own, riskiest first.

| # | Slice | Findings | State |
|---|---|---|---|
| 1 | System menu with a status line, one Rewrite submenu, Copy Last Dictation; menu bar icon with a shape per state; Start Meeting no longer opens the window | 3, 5, 14, 15, 16 | |
| 2 | Dictation panel reports the outcome: copied, nothing heard, cut short | 1, 2 | |
| 3 | Title and summary written when a meeting ends; default title without the date | 8, 9 | |
| 4 | Meeting pill: 30-point targets, Stop asks once | 6 | |
| 5 | History row: Show all, Insert names its target, undo for delete, no count | 7, 12, 27 | |
| 6 | Settings regrouped into seven tabs with a Status list; captions cut; one sound switch; four-way After typing; one name per thing | 4, 18–22, 24–26, 28, 30 | |
| 7 | Meetings window rework: layout to be chosen; selectable text, search inside a transcript, play from a word, import folded in, New Meeting button | 10, 11, 13, 17, 23, 29 | Waiting on the layout choice |

## Rabbit holes

- **A clock in the menu bar.** The recorder's elapsed time is derived, not observed, so
  the menu bar label needs something to tick it. Patch upfront: built first, in slice 1.
- **Removing the Raw prompt.** Stored choices may point at it: the global prompt, an
  app profile, a Shortcut. Call: the global choice migrates to "rewriting off"; app
  profiles keep the same stored id, now shown as "Off"; Shortcuts stop listing it.
- **Title quality.** The on-device model has not been tried on titles. Patch upfront:
  try the prompt on real transcripts before it ships; fall back to the first words
  spoken when the model is unavailable or fails.
- **Word timings for play-from-selection.** The recognizer already times every word;
  the app drops the timings when it groups words into lines. Keeping them means a new
  store schema version. Call: part of slice 7, with a migration; older meetings
  estimate the position inside the line.

## No-gos this pass

- Editing transcript words.
- A first-run setup window, Open at Login, an updater, localization. Proposed
  separately as public-release work.
- Recognizing a voice across meetings.
- The iOS target.
- Any network call.
