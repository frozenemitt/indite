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

The system font at system text styles, everywhere. No fixed point sizes except the
live clock. No serif: see the decisions log.

## Layout

- Menu bar: a system menu.
- Settings: tabs named for the job (Dictation, Rewriting, Words, Meetings, Feedback,
  Apps, About), each a grouped form.
- Meetings: a list beside a page, with no third column. The list's commands sit
  directly above it. The page reads top to bottom: title and speakers, summary,
  transcript, and a playback bar along the bottom. See `Docs/meetings-rework.md`.
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

SF Symbols. The menu bar icon is the ribbon, drawn as a template image, so state is
carried by shape.

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
- 2026-10-01 Meetings layout A, one page. "I agree with your recommendation on the
  meetings page layout. I like the summary at the top of the meeting with the
  transcript right below it."
- 2026-10-01 Commands sit beside what they act on. Of Delete at the far right: "I
  would have to select one on the left and then go delete it on the right." Delete
  moves above the list, and several meetings can be selected. "I like the idea of
  moving the delete in the toolbar directly above the list and allowing for multiple
  selection of meetings."
- 2026-10-01 Play audio from selected text. "I am very happy to hear that we can
  select text and play audio from the text. I would like to incorporate that."
- 2026-10-01 Recent Dictations and the type-again key. "I think those are really
  high value adds to the menu."
- 2026-10-01 The ribbon as the menu bar icon. "I like your menu ribbon icon option.
  I think that looks really cool."
- 2026-10-01 Serif for transcript text. "I don't really care about the reading face
  that much. I think that it looks nice having the serif font on the actual text. So,
  sure, go ahead and do it."
- 2026-10-01 Words in a transcript can be corrected. "If we could just be able to
  overwrite what's in the transcript with a correction, that would be an excellent
  addition."
- 2026-10-01 A window Inscribe opens comes to the front. Of windows opened from the
  new menu landing behind other apps: "That's very difficult because I don't know
  how to find them. So they need to be surfaced to the front when I open them."
- 2026-10-01 Space does not play or pause a meeting's audio. "Maybe we don't use the
  space key to play or pause the audio. Maybe there's another way to do it." The
  transcript is text and Space belongs to it; ⌘Return, the play button and the
  keyboard's Play/Pause key play and pause.
- 2026-10-01 No serif in the transcript. Tried in the installed app and rejected: "I've
  decided that I really don't like the serif font in the transcript. I think it's
  pretty ugly, actually." Overrides the same day's "sure, go ahead and do it". The
  transcript is set in the system font.
- 2026-10-01 The playing line is one soft rounded block, with a rounded mark on the
  word being said. Of the first version, bands of background color: "The
  highlighting of the speaker section is kind of awkward looking. I think this could
  be improved a lot."
- 2026-10-01 Following the audio word by word stays. "The command return works great
  for following the audio in the transcription. That is very cool."
- 2026-10-01 Deleting meetings is to be redesigned. Of the bar of buttons above the
  list and the confirmation on every delete: "I'm not super happy with the delete
  functionality. It feels really clunky. It doesn't feel very Apple at all."
- 2026-10-01 The rounded highlight stays. "I really like the new highlight interface
  that looks very good, much better than before."
- 2026-10-01 Deleting follows Voice Memos: at once, no dialog, into Recently Deleted
  for thirty days. "I like the recently deleted option." To be judged in use: "I need
  to see it and play around with it to really get an idea if it meets the Apple level
  of polish."
- 2026-10-01 A deleted meeting's date is kept in the database, on the meeting. Of
  keeping it in the app's preferences: "Is this really a good idea? What are the
  consequences?" Then: "Go ahead and move the 30 day date into the database."
- 2026-10-01 The selected meeting's highlight in the list is to be redesigned. It is
  the app's green at full strength with white text. "I don't love the green
  highlight of the conversation that's active. Could you propose a more Apple
  aligned view?" Options shown; none chosen yet.
