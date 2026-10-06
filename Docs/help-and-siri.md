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

1. **Siri finds and answers from one article.** One article indexed as an
   `IndexedEntity`, shown in a plain Help window when opened. Tested by asking Siri
   and by searching Spotlight.
2. **The assistant in the Help window**, with the article search tool, on Foundation
   Models.
3. **Settings as intents.** Siri and the assistant read and change Nscribe's settings.
   "I would love for Siri to be able to change the settings of Nscribe. That is true,
   agentic first design."
4. **Setup checks** as intents and tools.
5. **The full set of articles**, the searchable list, and onscreen awareness for
   "explain this".

## Decisions

- 2026-10-06 Siri reads the documentation and acts on the app: "I would love for Siri to
  be able to both read the documentation and be as agentic as it can be on its own,
  such as helping the user set up permissions."
- 2026-10-06 The first slice is Siri answering from an article: "I definitely want to do
  this 1st slice with the Siri help window and see how it works."

## Findings

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
