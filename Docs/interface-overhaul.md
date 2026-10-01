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
| 1 | System menu with a status line, one Rewrite submenu, Recent Dictations and a type-again key; the ribbon as the menu bar icon, with a shape per state; Start Meeting no longer opens the window | 3, 5, 14, 15, 16 | Installed 2026-10-01. Menu, submenus and icon seen working. Windows opened from the menu went behind other apps; fixed the same day, and the fix is unconfirmed until Jonathan opens one. The type-again key is untried. |
| 2 | Dictation panel reports the outcome: copied, nothing heard, cut short | 1, 2 | Installed. Jonathan saw "Nothing was heard" work. With no field in focus in Claude the panel said the paste was unconfirmed where it should have said copied; fixed, unconfirmed. |
| 3 | Title and summary written when a meeting ends; default title without the date | 8, 9 | Installed. Jonathan recorded a short meeting and the title was written. |
| 4 | Meeting pill: 30-point targets, Stop asks once | 6 | Installed. Untried on screen. |
| 5 | History row: Show all, Insert names its target, undo for delete, no count | 7, 12, 27 | Installed. Untried on screen. |
| 6 | Settings regrouped into seven tabs with a Status list; captions cut; one sound switch; four-way After typing; one name per thing | 4, 18–22, 24–26, 28, 30 | Installed. Dictation, Rewriting, Meetings and Feedback seen working. |
| 7 | Meetings window rework, layout A | 10, 11, 13, 17, 23, 29 | Built and installed on the branch `meetings-rework`; see `Docs/meetings-rework.md` for what has been seen working. |

Slices 1 to 6 are merged to main and pushed (451d3ef). FluidAudio 0.17.4 is merged too: Jonathan recorded a meeting with it on 2026-10-01 and its speakers were labelled.

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
  the app drops the timings when it groups words into lines. Call: kept in a file
  beside the recording, with no change to the store. See `Docs/meetings-rework.md`.

## No-gos this pass

- Editing transcript words.
- A first-run setup window, Open at Login, an updater, localization. Proposed
  separately as public-release work.
- Recognizing a voice across meetings.
- The iOS target.
- Any network call.
