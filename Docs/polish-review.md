# Polish review, 2026-10-03

Shipped the same day: the word being said is set in bold, as Voice Memos sets it on
iPhone, in place of the azure mark. Installed at 13:29.

What follows is everything else that stands between the app and Apple's own, sorted
by how often it is seen. It comes from the code and from what Apple's apps do in the
same place; no screen was photographed this session, so each item says what to look
at to confirm it.

## Verdict

The meeting page is one change from Voice Memos' level, and that change is the
playback bar. After it come four small things on the same page and in Settings,
each under an hour. The History window and the Words tab are the two larger pieces.

## Findings, most seen first

**1. The playback bar's transport.** What you see: a small push button with a play
glyph at the far left, a borderless back-15 glyph of a different weight beside it,
no forward 15, then the time, the strip, the length and the speed menu in a row.
Voice Memos: back 15, play, forward 15, three glyphs of one size and no border,
centered, with the current time at one end of the strip and the length at the
other. The change: the three glyphs centered as one group, forward 15 added, the
two times moved to the strip's ends, speed kept at the right. About an hour.

**2. The summary is set smaller than the transcript.** What you see: the summary's
points in callout, the transcript below in body. It is the first thing wanted on
the page and the one block set a size down. Notes and Journal set a note's body in
body. The change: body. One line.

**3. The toolbar moves when you copy.** What you see: "Copy as Markdown" becomes
"Copied" for two seconds, the button narrows, and the Export button beside it
slides over and back. Nothing in Safari's or Notes' toolbar moves when pressed. The
change: hold the button at the width of its longer title, or swap only the symbol.
Minutes.

**4. The page jumps to follow the audio.** What you see: while audio plays and the
playing line leaves the window, the page jumps to it. Voice Memos scrolls its
transcript smoothly. The change: animate the scroll in `mark(playing:following:)`.
The design doc says only the ribbon moves; a scroll is the system's own motion,
not decoration. About an hour.

**5. Captions that explain instead of warn.** The design doc's rule: a caption stays
only when it warns. Five explain. Dictation tab: "Works for two minutes after the
text was typed…" under the undo key, and "For a dictation that landed in the wrong
place…" under the type-again key. Rewriting: "Reads the text around your cursor…".
Meetings: "Written on this Mac by Apple's on-device model." Feedback: "The dictation
panel and the meeting pill share these…". The change: each becomes a tooltip or
goes. Minutes.

**6. The Feedback sliders are hand-built rows.** What you see: "Glass" and "Words
and ribbon" in a row with a label column fixed at 120 points, inside a grouped form
whose other rows align to the form's own columns. To confirm on screen. The change:
`Slider` with its own label, or `LabeledContent`. Minutes.

**7. Vocabulary in a code font.** What you see: names and jargon typed in
monospaced type. System Settings' Text Replacements are in the system font. The
change: the body font. One line.

**8. Apps without their icons.** What you see: "Mail", "Messages", as text at the
head of each profile. System Settings shows the app's icon beside every app name,
in Login Items and Notifications alike. The change: the icon from `NSWorkspace`,
by bundle identifier, beside the name. About an hour.

**9. History rows carry a bar of buttons.** What you see: under every dictation,
Copy, Insert into Mail, Copy Original and a trash can, in caption type. Apple's
lists keep the row to the thing itself and put the commands in the toolbar for the
selected row, the right-click menu and a swipe. The change: rows select; Insert
and Copy go to the toolbar and the context menu; delete is the Delete key and a
swipe. Half a day.

**10. Word Replacements as rows of fields.** What you see: a "heard → written" pair
of fields per row with a minus button, and an Add button below. System Settings'
Text Replacements is a two-column table with + and − under it. The change: a
`Table`. Half a day.

**11. The About tab's tagline.** "Background Voice Transcription", where the design
doc says the app "turns speech into text on the Mac". One line.

## Weighed and left

- **Dropping the azure block behind the playing line.** Voice Memos has none; the
  bold word and the scrolling carry it. Kept, because you chose the block on
  2026-10-01. Question 1 below.
- **Setting the transcript in gray, as Voice Memos does.** On iPhone the whole
  transcript is secondary and the bold word is the one black thing, which is why it
  jumps out there. Left out: the transcript here is read and typed into, and gray
  body text at 13 points reads worse than the gain.
- **Semibold rather than bold.** Semibold is the speaker names' weight; the same
  weight on the word being said would blur the two. Bold matches the iPhone.
- **Space to play.** Decided against on 2026-10-01: the transcript is text.

## Answered and built, 2026-10-03

Jonathan kept the azure block ("I think that does help identify where we are") and
asked for all eleven. Built the same afternoon and installed at 15:46.

Seen on screen: the playback bar's strip row and centered transport (1), the Feedback
sliders in the form's columns (6), Vocabulary in the system font and Word
Replacements as a table (7, 10), the captions gone from the Dictation, Rewriting and
Meetings tabs (5), the About tagline (11), the History window's toolbar (9), and the
bold word moving to 0:15 on a skip in the paused page. Not seen: the toolbar holding still on
Copy (3); the smooth scroll while audio plays (4); an app's icon in its profile (8),
since no profile exists on this Mac.

The summary in body (2) was seen once a meeting had one, and showed a fault older
than the review: Show all unfolded nine points into the height of three, and every
point was cut to one line. The header is now hosted at its own height and asks the
page for a layout pass when that height changes. Seen unfolding and folding on
screen on 2026-10-03 at 16:04.

In 9 the toolbar first held five buttons and overflowed at the window's width;
Copy Original and Clear All moved into a More menu.

## Seven more, 2026-10-03

Found on a second look after the eleven, asked for in full ("Go ahead and do all
seven"), built and installed at 16:17.

1. An import gets the title and summary a recorded meeting gets when it ends. It
   used to be named after its file, and a recording's file is named by a UUID; a
   UUID now counts as a default title.
2. Meetings still titled by their date, or by a file's name, are retitled when the
   Meetings window opens. Seen: the nine dated titles and the UUID were rewritten
   by the model within a minute of the window opening.
3. One name for the list of past dictations: Recent Dictations, in the menu, on the
   window and in Settings. Seen on the window and in the Window menu.
4. The Show all link in a Recent Dictations row is gray, which turns white on the
   azure of a selected row. Seen only in an inactive window, where the selection
   is gray and the link stays readable.
5. Prompts are set in the system font. Seen.
6. Escape is a tooltip on the dictation key's picker, not a settings row. Seen.
7. Show All in the menu has no ellipsis. Not seen: the menu bar's menu cannot be
   photographed from here.
