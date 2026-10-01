---
name: Inscribe
version: 1
---

## Overview

Inscribe turns speech into text on the Mac: dictation into any app, and recorded
meetings kept as transcripts. It is open source and meant for a wide public, not one
user. It should feel like part of macOS: you notice your words, not the app.

The one thing a person remembers: the ribbon of light that moves with their voice.

## References

- Voice Memos and Notes, for the Meetings window: a list, a page, system chrome.
- System Settings, for Settings: grouped forms, one job per pane.
- The macOS menu bar's own menus, for the menu.

## Colors

System colors throughout, so light and dark and the user's accent color work.
The ribbon has the only colors of Inscribe's own, defined in `ListeningBar.swift`:

- Azure `(0.24, 0.60, 1.00)` and violet `(0.62, 0.38, 1.00)` while listening.
- Amber `(1.00, 0.70, 0.32)` while the AI rewrites.
- White at the center line.

Speaker colors in a transcript come from the system palette, by speaker number.

## Typography

The system font at system text styles. No fixed point sizes except the live clock.

## Layout

- Menu bar: a system menu.
- Settings: tabs named for the job (Dictation, Rewriting, Words, Meetings, Feedback,
  Apps, About), each a grouped form.
- Meetings: a list beside a page. The page layout is under review; see the epic.
- Floating panels: glass, dark, draggable, on every desktop.

## Elevation & Depth

Liquid Glass on the two floating panels only. No drawn shadows.

## Shapes

System shapes. The dictation panel's corner radius is 26; the meeting pill is a capsule.

## Components

- Native controls before custom ones. A custom control has to do something the native
  one cannot.
- One name per thing: the dictation key, the dictation panel, the meeting pill,
  speaker separation, rewriting.
- A caption under a setting stays only when it warns: recording other people, writing
  to disk, downloading. Mechanism and rationale go in a tooltip or go away.
- A failure is said where the person is looking: in the dictation panel, in the pill,
  on the first line of the menu.

## Motion

The ribbon moves with the voice and with nothing else. Reduce Motion holds the
rewriting ribbon still. No animation on menus or frequent actions.

## Imagery

SF Symbols. The menu bar icon is a template image, so state is carried by shape.

## Do's and Don'ts

- 2026-10-01 Keep the stock macOS look. "I think I want to keep the stock macOS look,
  but I am open to seeing some mockups if you would like to show me some options that
  might look better."
- 2026-10-01 No live transcript in front of a meeting. "I do watch the live
  transcripts while dictating, but we don't tend to watch it during a meeting. I think
  it's actually more distracting during a meeting."
- 2026-10-01 No Skip AI. "I never used the Skip AI button. I always just turn it off
  or on."
- 2026-10-01 Design for the public. "Ideally Inscribe will be used by millions of
  people through its open source, sharing on GitHub."

## Decisions log

- 2026-10-01 The dictation panel reports the outcome. "Definitely, yes, for change
  one. I really like that idea."
- 2026-10-01 A meeting gets a title and a summary when it ends. "Yes, I like the idea
  of the meeting getting a title and the summary at the end."
- 2026-10-01 The menu becomes a system menu with a status line. "I absolutely love
  the proposal for change number three."
- 2026-10-01 Settings regrouped by job. "The settings regrouping also is a great
  idea. Let's go with that."
- 2026-10-01 Transcript text is selectable and searchable. "I really like this idea
  of being able to search and select text within a meeting." Asked for: play the
  audio from the selected text.
- 2026-10-01 Meeting pill with larger targets and a confirmation on Stop. "The
  meeting pill proposal is excellent. Let's go with that."
- 2026-10-01 History rows get Show all. "Also go on the history row with the show
  all button."
- 2026-10-01 Every deletion in the review is approved. "I agree with all of the
  suggested deletions as well."
- 2026-10-01 The Meetings window gets a full rework; the layout is not chosen yet.
  "Think about a total overhaul for the meetings UI. I'm sure there are some
  efficiency and experience improvements we can make."
