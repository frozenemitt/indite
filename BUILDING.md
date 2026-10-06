# Building Nscribe

## Build from source

You need **Xcode 27**, free from the App Store. Open Xcode once after installing it,
so it can finish setting up its tools. No Apple Developer Program membership is
needed.

```bash
git clone https://github.com/frozenemitt/nscribe.git
cd nscribe
Scripts/install.sh
```

The script builds Nscribe, puts it in `/Applications`, and launches it. The first
build downloads two packages, FluidAudio and Sparkle, and takes a few minutes; later
builds are faster.

To build in Xcode instead, open `Nscribe.xcodeproj`, choose your own team under
Signing & Capabilities for the Nscribe target (a free Apple ID works), and press Run.

Each rebuild is a new app to macOS, and it forgets the Accessibility grant: remove
Nscribe from the Accessibility list and add it again. The downloaded app keeps one
signature from version to version, so its grants carry over.

## Versions

Versions read like 1.0.352. The first two parts are raised by hand: the second when
something new ships, the first for a change big enough to say so. The third is the
number of commits the app was built from, so it rises with every build, fixes
included, and any two builds can be told apart. **Settings → About** shows it. Releases
are tagged with the whole version, such as `v1.0.352`, and listed under
[Releases](https://github.com/frozenemitt/nscribe/releases).

## Releasing

`Scripts/release.sh` makes a release: it builds and signs the app, puts it in the
disk image `Nscribe.dmg`, and writes the appcast that tells installed copies about it.
The notes are in [Docs/Releases](Docs/Releases): `whats-new.md`, rewritten for every
release and shown in Software Update and What's New, and the about text for the
release page.

## Design

The look and the decisions behind it are in [DESIGN.md](DESIGN.md), with the words
that settled each. The larger pieces of work are shaped in [Docs](Docs) before they
are built.

## Project layout

```
Nscribe/
├── NscribeApp.swift          Entry point, the store, the scenes
├── Models/                  SwiftData: meetings, speakers, lines, dictations, the schema
├── Services/
│   ├── GlobalHotkeyMonitor  The dictation key, through a CGEvent tap
│   ├── TranscriptionEngine  Apple's SpeechAnalyzer, streaming
│   ├── RecordingCoordinator One dictation, from the key press to the typed text
│   ├── TextInsertionService Finding the focused field and typing into it
│   ├── AIProcessor          Rewriting, titles and summaries, with Foundation Models
│   ├── MeetingRecorder      One meeting, from Start to saved
│   ├── SystemAudioCapture   The other side of a call, through a Core Audio tap
│   ├── MeetingDiarizer      Speaker separation, with FluidAudio's CoreML models
│   ├── MeetingPlayer        Playback, and the word being said
│   └── …
└── Views/
    ├── MenuBarView          The menu
    ├── DictationOverlay     The ribbon panel
    ├── MeetingIndicator     The meeting pill
    ├── MeetingsView         The list of meetings
    ├── MeetingPageView      One meeting: title, summary, transcript, playback
    ├── TranscriptTextView   The transcript, as one text that plays and corrects
    ├── Settings*Tab         Settings, one tab per job
    └── WelcomeView          The first launch
```

## Dependencies

| Dependency | For |
|---|---|
| [FluidAudio](https://github.com/FluidInference/FluidAudio) | Speaker separation, with pyannote's CoreML models |
| [Sparkle](https://sparkle-project.org) | Updates from inside the app |

Everything else is Apple's: SwiftUI, SwiftData, Speech, FoundationModels,
AVFoundation, CoreAudio, ApplicationServices and AppIntents.
