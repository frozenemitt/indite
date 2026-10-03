# Inscribe

[![macOS 27](https://img.shields.io/badge/macOS-27-blue.svg)](https://www.apple.com/macos/)
[![Swift 6.2](https://img.shields.io/badge/Swift-6.2-orange.svg)](https://swift.org)
[![MIT License](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)

**Hold a key, talk, and the words appear where your cursor is. Record a meeting and
read it back by speaker. Nothing leaves your Mac.**

Inscribe is a dictation and meeting app for the Mac, free and open source. It lives in
the menu bar as a ribbon that moves with your voice. Transcription runs on Apple's
speech recognizer, rewriting and summaries on Apple's on-device model, and speaker
separation on CoreML models that run locally.

## Build and run

There is no download. You build the app on your own Mac, which takes a few minutes
and costs nothing: no Apple Developer Program membership is needed.

You need **macOS 27** and **Xcode 26**, free from the App Store. Open Xcode once after
installing it, so it can finish setting up its tools.

```bash
git clone https://github.com/frozenemitt/inscribe.git
cd inscribe
Scripts/install.sh
```

The script builds Inscribe, puts it in `/Applications`, and launches it. The first
build downloads one package, FluidAudio, and takes a few minutes; later builds are
faster.

To build in Xcode instead, open `Inscribe.xcodeproj`, choose your own team under
Signing & Capabilities for the Inscribe target (a free Apple ID works), and press Run.

### The first launch

Inscribe appears in the menu bar as a ribbon. A welcome window says what the key does
and what macOS will ask for.

| Permission | Needed for | Asked |
|---|---|---|
| **Microphone** | hearing you | by macOS, the first time you dictate |
| **Speech Recognition** | turning speech into text | by macOS, the first time you dictate |
| **Accessibility** | the dictation key, and typing into other apps | by you, in System Settings → Privacy & Security → Accessibility |
| **Screen & System Audio Recording** | hearing the other side of a call, in meetings | by you, in System Settings, only if you switch it on |

Set **System Settings → Keyboard → "Press 🌐 key to"** to *Do Nothing*, or macOS will
also switch your input source each time you dictate. The key can be changed in
Settings → Dictation.

If you rebuild the app, macOS treats it as a new app and forgets the Accessibility
grant: remove Inscribe from the Accessibility list and add it again.

## Dictation

- **Hold the Globe key and talk**, or press once to start and again to stop. Escape
  discards a dictation.
- **The words are typed where your cursor is.** With no text field in front, they go
  to the clipboard, and the panel says so.
- **The ribbon panel** shows the words as they arrive, and says how the dictation
  ended.
- **Rewriting**, with Apple's on-device model: clean up, summarize, make formal, or a
  prompt of your own. It can read the text already in the field, so a dictated reply
  matches the thread above it.
- **Words you use**: vocabulary the recognizer should prefer, and replacements for
  words it mishears.
- **Per-app profiles** choose the prompt and where the text goes, by the app you are
  dictating into.
- **Recent dictations** are kept, so one that landed in the wrong window can be put
  where it belongs. An undo key takes the last one back; a type-again key types it
  again.

## Meetings

- **Start Meeting** from the menu bar. A small pill shows the meeting is still being
  heard, with Pause and Stop.
- **The other side of a call** is recorded through a system audio tap, alongside your
  microphone, when you switch that on.
- **Speakers are separated** when the meeting ends, and each is named by you.
- **A title and a summary** are written when the meeting ends.
- **The transcript plays.** Click a word to hear it; the word being said is set in
  bold as the audio runs. Lines can be corrected by typing over them, given to
  another speaker, or split.
- **Import a recording** or a video, and it gets the same treatment.
- **Export** as Markdown or plain text. **Deleted meetings** wait thirty days in
  Recently Deleted.

## Privacy

Everything runs on this Mac. Audio and text are never uploaded.

Inscribe reaches the network for two things only, and never with your data:

- Apple downloads its speech model on first use.
- The speaker models (pyannote community-1, through FluidAudio) download from
  HuggingFace only when you press Install Models in Settings → Meetings. Check for
  Updates reads the repository's public metadata, and the installed files are
  verified against the hashes HuggingFace publishes.

Recent dictations are kept in plain text on this Mac. That is a setting, and it can be
switched off.

The Mac app is not sandboxed, on purpose: macOS never grants Accessibility to a
sandboxed process, and without it there is no dictation key and no typing into other
apps. That also rules out the Mac App Store.

## Versions

Releases are tagged `v1.0`, `v1.1` and so on, and listed under
[Releases](https://github.com/frozenemitt/inscribe/releases). The version goes up by
a tenth when something new ships and by a hundredth when only fixes do. The build
number beside it, in Settings → About, is the number of commits the app was built
from, so any two builds can be told apart.

## Design

The look and the decisions behind it are in [DESIGN.md](DESIGN.md), with the words
that settled each. The larger pieces of work are shaped in [Docs](Docs) before they
are built.

## Project layout

```
Inscribe/
├── ScribeApp.swift          Entry point, the store, the scenes
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

Everything else is Apple's: SwiftUI, SwiftData, Speech, FoundationModels,
AVFoundation, CoreAudio, ApplicationServices and AppIntents.

## License

MIT. See [LICENSE](LICENSE).

## Acknowledgments

Begun from [Swift Scribe](https://github.com/seamlesscompute/swift-scribe) by
seamlesscompute (MIT). The dictation and meeting features follow
[voxtype](https://github.com/peteonrails/voxtype). Speaker separation is
[FluidAudio](https://github.com/FluidInference/FluidAudio)'s.
