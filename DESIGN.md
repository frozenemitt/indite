---
name: Nscribe
version: 1
---

## Overview

Nscribe turns speech into text on the Mac: dictation into any app, and recorded
meetings kept as transcripts. It is open source and meant for a wide public, not one
user. It should feel like part of macOS: you notice your words, not the app.

The one thing a person remembers: the ribbon of light that moves with their voice.

## References

- Voice Memos and Notes, for the Meetings window: a list, a page, system chrome.
- System Settings, for Settings: grouped forms, one job per pane.
- The macOS menu bar's own menus, for the menu.

## Colors

System colors throughout, so light and dark and the user's accent color work.
The app's own accent color is the ribbon's azure, `#3D99FF`. It colors the selected
meeting, the default button, switches, and the block behind the line being played.
The word being said carries no color: it is set in bold.
The ribbon has the only colors of Nscribe's own, defined in `ListeningBar.swift`:

- Azure `(0.24, 0.60, 1.00)` and violet `(0.62, 0.38, 1.00)` while listening.
- Amber `(1.00, 0.70, 0.32)` while the AI rewrites.
- White at the center line.
- In light mode, an edge of deep azure `(0.10, 0.42, 0.95)`, or deep amber
  `(0.90, 0.48, 0.05)` while the AI rewrites.

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
- Floating panels: Apple's Regular glass, draggable, on every desktop. The dictation
  panel follows the system appearance; the meeting pill stays dark.

## Elevation & Depth

Liquid Glass on the two floating panels only. No drawn shadows.

## Shapes

System shapes. The dictation panel's corner radius is 26; the meeting pill is a capsule.

## Components

- Native controls before custom ones. A custom control has to do something the native
  one cannot.
- One name per thing: the dictation key, the dictation panel, the meeting pill,
  speaker separation, rewriting, recent dictations (the menu, the window and the
  setting; the window was Dictation History and the setting was History).
- A caption under a setting stays only when it warns: recording other people, writing
  to disk, downloading. Mechanism and rationale go in a tooltip or go away.
- A failure is said where the person is looking: in the dictation panel, in the pill,
  on the first line of the menu.

## Motion

The ribbon moves with the voice and with nothing else. Reduce Motion holds the
rewriting ribbon still. No animation on menus or frequent actions.

## Imagery

SF Symbols. The menu bar icon is the app icon's N, drawn as a template image, so
state is carried by shape: the N at rest, the N knocked out of a filled tile while a
dictation is heard, and symbols for the meeting, the rewrite and a failed key.

## Do's and Don'ts

- 2026-10-01 Keep the stock macOS look. "I think I want to keep the stock macOS look,
  but I am open to seeing some mockups if you would like to show me some options that
  might look better."
- 2026-10-01 No live transcript in front of a meeting. "I do watch the live
  transcripts while dictating, but we don't tend to watch it during a meeting. I think
  it's actually more distracting during a meeting."
- 2026-10-01 No Skip AI. "I never used the Skip AI button. I always just turn it off
  or on."
- 2026-10-01 Design for the public. "Ideally Nscribe will be used by millions of
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
- 2026-10-01 A window Nscribe opens comes to the front. Of windows opened from the
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
- 2026-10-01 Green is not Nscribe's color. It is the accent color the project was
  created with (#00AB83, in the first commit) and nobody chose it. "I don't know
  where you got this idea of green being our app color, but I don't think that is
  our app color."
- 2026-10-01 The selected meeting is highlighted in the app's color, as Notes does:
  gray for the selected folder in the sidebar, the app's yellow for the selected
  note. Neutral gray for the meeting was offered and turned down. "I think the
  active meeting should be highlighted in an app color, and the green is definitely
  not it." Which color is the app's is not chosen yet.
- 2026-10-01 Nscribe's color is azure, the ribbon's. Chosen over coral from the app
  icon, which was recommended, and violet: "Azure". Installed the same hour. The
  selected meeting is the system's own highlight, azure at full strength under white
  text. The soft tint under dark text that the mockup showed is not built: the list
  draws its highlight over any row background, so the tint needs the highlight
  switched off in the AppKit table behind the list. Jonathan has not chosen between
  the two.
- 2026-10-01 The selected meeting keeps the system's own highlight: azure at full
  strength under white text. The soft tint is not to be built. "keep the full tint"
- 2026-10-03 The word being said is set in bold, as Voice Memos sets it on iPhone,
  and not marked in color. "The word that's being played during the recording is
  highlighted, not in a color, but in bold. I really like that look, and I think
  we should adopt it." The soft azure block behind the playing line stays. The bold
  word is drawn in the slot its regular glyphs have, so the line does not move as
  the mark goes from word to word.
- 2026-10-03 The azure block behind the playing line stays, with the word in bold
  inside it. Voice Memos has no block. "I think I do want to keep the azure block
  behind the playing line. I think that does help identify where we are."
- 2026-10-03 All eleven findings of the polish review (`Docs/polish-review.md`) are
  built. "I want you to incorporate all 11 findings."
- 2026-10-03 Seven more, found on a second look: imports get the written title and
  summary, old dated titles are rewritten, one name for recent dictations, gray for
  the link in a selected row, prompts in the system font, Escape as a tooltip, no
  ellipsis on Show All. "Go ahead and do all seven."
- 2026-10-03 Three things for the public, and the first release. A welcome window on
  the first launch, Help opening the README, and the GitHub link and license in
  About. The app as it stands is 1.0, tagged and released; the version rises by a
  tenth for something new and a hundredth for fixes, and the build number is the
  commit count. No Developer ID: people build it from source, free, with
  `Scripts/install.sh`. "Could you go ahead and create those 3 things." "Keep the
  explanation of building it from source and give really clear instructions."
- 2026-10-04 The app icon is settled: two quotation marks as the uprights of an N,
  a chisel across them. Each mark is one stroke, rounded at both ends and narrowing
  toward the tail, leaning twelve degrees; the chisel is a plain bar with its edge
  cut on a slant, lying at forty-five degrees over the marks as smoked glass, butt
  at the top-left. The tile is a shade of black, the shapes white. Chosen over
  stone-cut V-grooves ("the shadows do not work"), ball-and-tail commas ("the
  bulbous end and the pointed end are exaggerated"), a facet along the chisel's
  edge ("show me these without the 2 tone"), and the chisel turned the other way.
  "U2 looks great. I think that's it!" The marks read first, the N second, the
  chisel as a tool last, which is the order asked for. Drawn by
  `Design/Icon/draw-icon.swift`; the document is `Nscribe/AppIcon.icon`.
- 2026-10-04 The menu bar icon is the app icon's N, not the ribbon. "Let's change
  the menu bar icon to the actual AppIcon instead of using the audio waveform." The
  N is drawn from the icon's own shapes as a template image, the chisel lighter than
  the marks with a gap where it crosses them; while a dictation is heard the N is
  knocked out of a filled tile, which replaces the swollen ribbon. The ribbon stays
  in the dictation panel.
- 2026-10-05 Nscribe is downloaded as a disk image from GitHub Releases and updates
  itself through Sparkle. "I'm not paying Apple for sharing free software." "Add the
  in-app updater." Without a Developer ID, the first open goes through Open Anyway
  in System Settings; updates installed by Sparkle are not marked as downloaded, so
  they open without asking. Releases are signed with the Apple Development
  certificate the project already uses, so every version has one identity and keeps
  each user's permissions. The update check is the one network call Nscribe makes
  unasked, and Sparkle asks on the second launch before making it on a schedule.
  This replaces "people build it from source"; `Scripts/install.sh` stays for those
  who want to.
- 2026-10-05 Nscribe is a menu bar app. "I definitely want to make this a menu bar
  only app." It joins the Dock and Command-Tab while any of its windows is open, so
  the Meetings window can be switched back to and every window has the Edit menu.
  "When the meetings window is open, I do want it to show in the command tab."
- 2026-10-05 Updates are on by default, chosen by one switch in the welcome window
  and kept in Settings → About; Sparkle's own question is gone. "The default should
  be on." A downloaded update is announced by a notification and a line at the top
  of the menu that restarts the app to install it. "For most people, they're
  probably gonna be using this all of the time and never restart it … so we need
  some way of prompting them to restart."
- 2026-10-05 Simple Clean is built in. It began as Jonathan's own prompt: "I really
  like it. It's working very well for me."
- 2026-10-05 The version's third part is the build number: 1.0.352, not 1.0 (352).
  "The build number should be shown as a second dot. … It's much easier to read
  than putting something in parentheses." This replaces the tenth-and-hundredth
  rule: fixes no longer get a number of their own, since every build raises the
  third part. Releases are tagged with the whole version.
- 2026-10-05 The welcome window says the Globe key can be changed, with a link to
  Settings → Dictation. "We should make it clear in the welcome screen that that is
  a customization that can be made."
- 2026-10-05 The welcome window has a second page, Get Set Up: a checklist that
  ticks itself off (Accessibility, the microphone and speech recognition, and the
  Globe key's own macOS setting when it is not Do Nothing), a box to try a
  dictation in, a line saying where everything lives, and the update switch. "I
  love the ideas for the welcome screen. I want you to incorporate all 3 of them."
  The reason: "If it's hard to understand how to use it to start out with, then
  people will give up very quickly." macOS's Accessibility prompt no longer opens
  over the window at launch; the checklist asks instead.
- 2026-10-05 The welcome window's first page is only a welcome and a short summary
  of what Nscribe does; everything practical, the key choice included, moves to the
  second page, a guided setup. Both pages carry the icon and the name. "The 1st page
  should just be a very generic welcome and quick summary of what the app does. The
  second page should be a very helpful, guided setup page." "Make sure the 2nd page
  is also branded with the logo and the name."
- 2026-10-05 Don't narrate the interface. "Saying each item ticks itself once it's
  done is obvious and very amateur. Make sure this is written and drawn as a
  professional app."
- 2026-10-05 The welcome window follows Apple's own first-run windows: a quiet first
  page in the manner of Freeform's or Journal's welcome, and a setup page laid out
  like a System Settings pane, with the icon and the name at the top and numbered
  steps in a grouped list. System font, the azure accent; the ribbon appears only in
  Try it, while the user speaks. Chosen over a dark glass band across the top of
  both pages. "I like your recommendation."
- 2026-10-05 Every window a user meets around installing and updating is designed
  as one family. "Be sure to include all windows, like the update window and the
  what's new in this version window as you're designing so that everything is
  coherent."
- 2026-10-05 After two critic rounds (5/10 both), the critic loop stops; the second
  critic mostly reversed the first and the decisions above. The remaining craft fixes
  are: one left edge inside every box with icons in a fixed column, nothing moving
  when a permission is granted, finished steps at full contrast, the restart-wait
  buttons named for what they do, and one width and one margin across the windows.
  "Keep going with the five fixes."
- 2026-10-05 Removed from the window family: the "Allowed" labels beside the checks,
  the page dots, "made on your Mac" in the welcome subtitle, the symbols that only
  filled the alignment column, the rules around release notes, and the lines under
  "Checking for Updates…" and "Preparing…". "Remove all seven."
- 2026-10-05 The README opens as a storefront, as IINA, Loop, Ice and CodeEdit do:
  the icon, the name, the tagline, one Download for macOS link, a row of links, then
  the meeting screenshot. "Go with the storefront header."
- 2026-10-05 Every image in the README is centered on its own line. "I think all
  images should be centered, laying them out like a journal doesn't really make
  sense in GitHub."
- 2026-10-06 The README leads with a dictation clip, not the meeting screenshot. "I like
  the idea of the dictation clip."
- 2026-10-06 Removed from the README: the badge row, the row of section links, the intro
  paragraph (its sentence on what runs where moved to Privacy), the still of the panel
  under Dictation, and "an N made of two quotation marks". "I agree with the removal
  proposals."
- 2026-10-06 The dictation panel follows the system appearance. In light mode the ribbon
  keeps its white core, given a thin blue edge and a colored halo in normal blending;
  the glass takes a light tint, the rim a dark outline, the text dark. Chosen over a
  deep blue center ("reads as a marker") and a colored rim. "I agree with direction 2
  for the light mode." This replaces "Floating panels: glass, dark" for the dictation
  panel.
- 2026-10-06 The light panel, tried on Jonathan's desktop, stays as built. "I think it
  looks good. It's bouncing a little bit with background noise, but I don't think it's
  any different than in dark mode."
- 2026-10-06 The Help window opens on a question, not on an article: one field, what to
  ask, three example questions, and the article list behind the sidebar button and a
  "Browse all articles" link. Ask Nscribe is in the menu, on ⌘? and in Siri. "The
  landing of the help window should just be a search bar with instructions to say
  what you're looking for. I think the menu should be accessible as well, but I don't
  want that to be the default."
- 2026-10-06 Help has one field. Typing narrows the articles beneath it, Return asks the
  assistant, and the answer sits above the matching articles, as the Help menu's search
  works. No sidebar. Chosen over the field in the toolbar beside an article sidebar,
  and over a conversation with the field at the bottom. "It's really awkward having 2
  separate places to put your question." "Go with A."
- 2026-10-06 Help follows the AI labs' own products, not a help-center index: "Look at
  what anthropic and their other AI labs are doing on their websites. Those are
  probably good models to follow." The articles are not listed under the field: "I
  don't want to list all the articles on one page like this, but instead, I think
  there should be a link to browse all articles manually, and then maybe like the
  search bar would collapse at the top, so they could go back to the agentic search."
  Rejected: titling each article as a question and asking it on click ("I'm not sure I
  agree with this").
- 2026-10-06 The menu says Help: "Help" in Nscribe's menu, and "Nscribe Help" on ⌘? in
  the Help menu, replacing "Ask Nscribe…". "I do think it should say help, because
  that's what people are looking for in the menu."
- 2026-10-06 Help articles may name other companies' products, such as AirPods, Slack
  and Zoom, because people ask with those words: "Yeah, that's totally fine." The
  README still compares Nscribe to no one.
- 2026-10-06 The README keeps "Click a word to hear it", though a click moves the
  playhead and Play starts the sound: "People will understand that they need to click
  play." The Play button's tooltip names ⌘↩.
- 2026-10-06 Nscribe transcribes in the Mac's language: the first preferred language
  Apple's recognizer supports, and US English when it supports none. Chosen over a
  Language menu in Settings: "Follow the Mac's language automatically." A rewrite is
  told the dictation's language when it is not English, because Clean Up turned
  German and French dictations into English.
- 2026-10-06 A Help article's settings button opens Settings at the tab the article
  names: "make sure that the settings links go to the correct tab in the settings
  window from the help article." "Record both sides of a call" opens Meetings, where
  its switch is, rather than the macOS privacy pane.
- 2026-10-06 Both floating panels use Apple's Regular glass, untinted, with no Glass or
  Words and ribbon slider and no drawn rim. The clear glass, faded by the Glass slider,
  let the text behind show through under the words, and Regular frosts it away. "Ok,
  let's keep Regular." "Remove both sliders and switch the pill to Regular too." Tried
  and turned down first: a blur switch that only frosted, tunable blur through private
  window-server and Core Animation calls, Apple's private glass variants, and Bubbles'
  bending rim over Regular's frost, which left a hard seam. This replaces the light
  panel's tint and drawn rim. The pill keeps its dark form.
