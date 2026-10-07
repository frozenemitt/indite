# Help and Siri

Shaped 2026-10-06 with Jonathan. Nscribe is meant to be agent first: what a person can
learn or change in it, Siri and an assistant inside the app can too.

## Problem

Nscribe has no documentation inside the app. A question such as "how do I change the
dictation key?" sends a person to the README, which by decision describes what the app
does and not how to operate it. Nothing lets Siri answer questions about Nscribe, check
why something is not working, or change a setting when asked.

## Solution sketch

**One set of help articles** is the source for everything. Each is short, specific and
written for a person: one task or one question per article.

**Siri** reaches the articles and the settings through App Intents, which in the 27
releases are the only way Siri calls into an app.

- Each article is an `IndexedEntity`, indexed into the system's semantic index, so Siri
  can search the articles, reason over them and answer from them.
- Each setting a person might ask Siri to change is an App Intent that reads or sets
  it. "Turn off the live panel" and "use Control-Option-D for dictation" become
  actions.
- Setup checks are App Intents too. They report what is missing (the Accessibility
  grant, the Globe-key setting, Apple Intelligence) and open the right place.

**An assistant inside Nscribe** uses the same pieces through Foundation Models tool
calling, on the Mac: a tool that searches the articles, one that reads the settings and
one that changes them. The Help window holds it, together with a searchable list of the
articles.

## Rabbit holes

- **Siri answering from articles.** Apple's examples index entities that fit one of its
  schema domains, such as messages and contacts. A help article fits none. Whether Siri
  answers questions from an `IndexedEntity` that conforms to no schema is unknown, and
  slice 1 exists to find out.
- **Siri calling custom intents without fixed phrases.** Schema intents are understood
  in any wording; custom intents may need App Shortcut phrases. Found out in slice 3.
- **Permissions.** macOS lets no app grant itself a permission. Siri and the assistant
  can say what is missing and open the pane, never grant it.

## No-gos

- Siri or the assistant reading the source code to answer questions. "Eventually it
  would be great if Siri can just read the code and answer questions directly, but I'm
  not sure if it's actually there yet."
- Anything that needs a server.

## Slices

1. **Siri finds and answers from one article.** Done: Siri reaches Help through
   "Search Nscribe for …" but never answers from the articles. See Findings.
2. **The assistant in the Help window**, with the article search tool, on Foundation
   Models. Shipped in 1.1.
3. **Help that knows your setup**, replacing "settings as intents" and "setup checks".
   Shaped below.
4. **The full set of articles** and the browsable list. Shipped in 1.1, 55 articles.
   Onscreen awareness for "explain this" is not shaped.

Dropped: Siri changing Nscribe's settings. No Siri schema covers an app's settings,
custom commands need fixed phrases, and the in-app assistant chose the right article
for 19 of 24 fresh questions, too few to let it change a setting by itself.

## Slice 3: Help that knows your setup

**Problem.** When dictation fails, the cause is usually state the person cannot see:
Accessibility off, the Globe key opening emoji, the microphone or speech recognition
refused, Apple Intelligence off or still downloading, the speaker models missing. Help
answers in general terms ("Nscribe most likely lacks Accessibility") although the app
knows the answer. Settings' Status list knows it too, but only someone who opens
Settings sees it.

**Solution sketch.**
- One account of the setup, read from the checks the Status list and the welcome
  window already make: the dictation key and whether its tap runs, Accessibility,
  microphone, speech recognition, Apple Intelligence, the speaker models, the Globe
  key setting, and whether meetings are being saved. Plus the settings a question
  can turn on: the dictation key and its mode, the rewrite prompt, where text goes,
  the microphone. Read only.
- The assistant gets it as a second tool, so an answer can say "Accessibility is
  off" rather than "most likely".
- The fix stays one press for the person: the answer's button goes to the exact
  place, Nscribe's Settings tab or the System Settings pane (Accessibility,
  Microphone, Speech Recognition, Keyboard).
- First vertical cut: "my key does nothing" answered with the real state of
  Accessibility and the tap, and a button to the Accessibility pane.

**Rabbit holes.**
- The small model may state a fact wrongly or ignore it. Patch upfront: the facts
  come from code as plain sentences, and a failing check that matters to the question
  is shown by the app above the answer, not left to the model's wording.
- System audio permission cannot be read; macOS gives no way. Out of scope; the
  article already says so.
- The Globe key setting lives in another app's preferences. The welcome window
  already reads it; reuse that.

**No-gos.** The model changing a setting. Siri. Anything from the person's
dictations or meetings in what the model reads. New Settings UI.

**As built (2026-10-06, branch setup-aware-help).** Help shows the checks itself; the
model is told nothing about the setup. Help's opening screen lists every urgent
problem with its button ("yes, show it on the opening screen too"). Above an answer it
shows the problems that bear on the articles the answer drew on, and, for a
troubleshooting article, the checks on it that came out fine. An answer's own button
is left out when a check above covers it. The settings were cut from the sketch: only
the model would have used them, and it could not be trusted with them. See Findings.

## Decisions

- 2026-10-06 Siri reads the documentation and acts on the app: "I would love for Siri to
  be able to both read the documentation and be as agentic as it can be on its own,
  such as helping the user set up permissions."
- 2026-10-06 The first slice is Siri answering from an article: "I definitely want to do
  this 1st slice with the Siri help window and see how it works."
- 2026-10-06 Help that knows your setup replaces Siri changing settings: "I think I
  prefer this over the Siri route anyway."

## Findings

- 2026-10-06, slice 3, twelve questions against made-up setups. Every way of giving
  the on-device model the setup made answers worse. As a tool of its own, it skipped
  the tool and blamed Accessibility on a Mac where Accessibility was on. Put before the
  question, it stopped searching the articles and invented settings ("the Keymap
  setting"). Put after the articles, it recited the settings into unrelated answers,
  invented problems ("it may fail to apply the new key combination") and still gave
  the Accessibility fix when told Accessibility was already fine. Help's own reading
  of which checks bore on an answer was right in all twelve. So Help shows the checks,
  and the model answers from the articles alone, as in 1.1.

- 2026-10-06, 1.1.444, Jonathan's Spotlight: typing "Ask Nscribe" lists the App
  Shortcut "Show Nscribe help.", the "Show Nscribe Help" action, and the help articles
  by their words. macOS has registered the shortcut; whether Siri runs it by voice is
  untested.

- 2026-10-06, slice 1, build 1.0.391. Siri answered all three test questions from the
  web, not from the articles: "How do I change Nscribe's dictation key?", "Why does my
  Globe key open emojis?" and even the App Shortcut phrase "Show Nscribe help". The
  build was registered: linkd logged "Interpolated com.nscribe.app.macos, donating to
  Siri…", and the metadata carries the intents, the phrases and the indexed entity.
  Two causes are visible:
  - corespotlightd logged "No IndexedEntityQuery found for entity type
    HelpArticleEntity". macOS 27 re-indexes through `IndexedEntityQuery`, which the
    query did not adopt. Fixed in the next build.
  - The entity conforms to no schema. Apple's session says Siri needs a schema to
    understand what an entity is, and none of the domains fits a help article: notes
    and reader would put help articles among a person's own notes or books. The next
    build adds the system `searchInApp` schema, so "search Nscribe for …" reaches the
    Help window in any wording.
- 2026-10-06, build 1.0.392, with `IndexedEntityQuery` and the `searchInApp` schema.
  "Search Nscribe for the dictation key" opened the Help window at the right article:
  the system schema reaches the app in any wording. "How do I change Nscribe's
  dictation key?" was still answered from the web: Siri did not answer from the
  indexed article. Spotlight showed Siri's own answer, not the article.
  Siri therefore routes into Nscribe but does not answer from its content. The
  assistant in the Help window becomes the place answers come from, and Siri's search
  hands it the question.
- 2026-10-06, Jonathan: "If we are sure that indexing is complete, then we can draw
  this conclusion, but otherwise, I don't think we can." He was right to doubt it. Two
  facts undercut the conclusion above:
  - Every launch deleted and re-indexed the articles, and each test install relaunched
    the app, so Spotlight never kept them for more than a few minutes. Build 1.0.395
    indexes only when the articles change.
  - Nothing measured whether the semantic index had them. A probe (build 1.0.396) now
    queries the app's own index at launch and every ten minutes for an hour. Two
    minutes after indexing: all three articles are in the index, the lexical control
    "emoji picker" finds its article, and the three questions worded unlike any article
    find nothing yet. The Siri conclusion waits on the probe.
- 2026-10-06, 11:56 to 12:49, build 1.0.396, index untouched by relaunches. In six
  rounds an hour apart in total, the lexical control "emoji picker" found its article
  every time and the three questions worded unlike any article found nothing every
  time. The semantic index never matched the articles by meaning within the hour.
  This Mac also gave no positive control that semantic search works for any app, so
  the cause is unproven; the effect is that Siri has nothing of Nscribe's to answer
  from. Slice 2, the assistant in the Help window, goes ahead: it answers from the
  articles directly and does not depend on Spotlight.
