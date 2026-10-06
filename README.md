<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="Docs/Images/wordmark-dark.png">
    <img src="Docs/Images/wordmark-light.png" width="320" height="186" alt="Nscribe">
  </picture>
</p>

<h3 align="center">Hold a key, talk, and the words appear where your cursor is.</h3>

<p align="center">Record a meeting and read it back by speaker. Nothing leaves your Mac.</p>

<br>

<p align="center">
  <a href="https://github.com/frozenemitt/nscribe/releases/latest/download/Nscribe.dmg">
    <picture>
      <source media="(prefers-color-scheme: dark)" srcset="Docs/Images/download-dark.png">
      <img src="Docs/Images/download-light.png" width="200" height="46" alt="Download for Mac">
    </picture>
  </a>
  <br>
  <sub>Free and open source · macOS 27</sub>
</p>

<br>

<p align="center">
  <img src="Docs/Images/dictation-clip.webp" width="658"
       alt="A dictation into Notes: the ribbon swells blue and violet as the words arrive in the panel, turns amber while they are cleaned up, and the sentence lands in the note">
</p>

## Dictation

- **The Globe key.** Hold <kbd>Globe</kbd> and talk, or press it once to start and
  again to stop. <kbd>Esc</kbd> discards a dictation.
- **Typing where your cursor is.** With no text field in front, the words go to the
  clipboard, and the panel says so.
- **The ribbon panel.** It shows the words as they arrive and says how the dictation
  ended.
- **Rewriting.** Apple's on-device model can clean up, summarize, make formal, or
  follow a prompt of your own. Simple Clean fixes only what the recognizer got wrong
  and keeps every other word as you said it. It can read the text already in the
  field, so a dictated reply matches the thread above it.
- **Words you use.** The recognizer prefers your vocabulary, and your replacements
  fix the words it mishears.
- **Per-app profiles.** Each one chooses the prompt and where the text goes, by the
  app you are dictating into.
- **Recent dictations.** Nscribe keeps them, so one that landed in the wrong window
  can be put where it belongs. <kbd>⌃⌥⌘Z</kbd> takes the last one back;
  <kbd>⌃⌥⌘V</kbd> types it again.

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="Docs/Images/rewriting-dark.png">
    <img src="Docs/Images/rewriting-light.png" width="760"
         alt="Settings, Rewriting: the built-in prompts with their In menu switches, and Simple Clean open for editing, showing its system prompt and its instructions">
  </picture>
  <br>
  <sub>Every prompt can be shown in the menu, edited, or copied as a custom prompt of your own.</sub>
</p>

## Meetings

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="Docs/Images/meeting-dark.png">
    <img src="Docs/Images/meeting-light.png" width="760"
         alt="A meeting in Nscribe: its title, the three speakers, a summary, and the transcript by speaker, with the word being played set in bold">
  </picture>
  <br>
  <sub>A meeting, read back by speaker. The word being played is set in bold.</sub>
</p>

- **Starting one.** Choose Start Meeting from the menu bar. A small pill shows the
  meeting is still being heard, with Pause and Stop.
- **The other side of a call.** When you switch it on, a system audio tap records it
  alongside your microphone.
- **Speakers.** Nscribe separates them when the meeting ends, and you name each one.
- **A title and a summary.** Both are written when the meeting ends.
- **Playback.** Click a word to hear it; the word being said is set in bold as the
  audio runs. Lines can be corrected by typing over them, given to another speaker,
  or split.
- **Imports.** A recording or a video gets the same treatment.
- **Export and deletion.** Meetings export as Markdown or plain text. Deleted
  meetings wait thirty days in Recently Deleted.

## Privacy

Everything runs on this Mac. Audio and text are never uploaded. Transcription runs
on Apple's speech recognizer, rewriting and summaries on Apple's on-device model, and
speaker separation on CoreML models that run locally.

Nscribe reaches the network for three things only, and never with your data:

- Apple downloads its speech model on first use.
- Once a day, and when you choose **Check for Updates…**, Nscribe reads a small file
  attached to the latest GitHub release. The request names the app and its version,
  and nothing else. The update it finds is signed, and Nscribe checks that signature
  before installing it. The daily check can be switched off in **Settings → About**.
- The speaker models (pyannote community-1, through FluidAudio) download from
  HuggingFace only when you press **Install Models** in **Settings → Meetings**. **Check for
  Updates** reads the repository's public metadata, and the installed files are
  verified against the hashes HuggingFace publishes.

Recent dictations are kept in plain text on this Mac. That is a setting, and it can be
switched off.

The Mac app is not sandboxed, on purpose: macOS never grants Accessibility to a
sandboxed process, and without it there is no dictation key and no typing into other
apps. That also rules out the Mac App Store.

## Install

1. **Download [Nscribe.dmg](https://github.com/frozenemitt/nscribe/releases/latest/download/Nscribe.dmg)**,
   open it, and drag Nscribe into Applications. Earlier versions and the notes for
   each are under [Releases](https://github.com/frozenemitt/nscribe/releases).
2. **Open Nscribe.** The first time, macOS says it cannot check Nscribe for malware,
   and offers only Done and Move to Trash. Nscribe is free and is not signed through
   Apple's paid developer program, which is what that check looks for. Click Done,
   open **System Settings → Privacy & Security**, and click **Open Anyway** next to
   the line about Nscribe. macOS asks for your password once.
3. **Allow what it asks for.** The welcome window lists each permission and ticks it
   off as it is done; [The first launch](#the-first-launch) has the details.

Dictation and meetings work on any Mac that runs macOS 27. Rewriting, titles and
summaries also need Apple Intelligence, which is switched on in **System Settings →
Apple Intelligence & Siri**; **Settings → Dictation** in Nscribe says whether it is ready.

Nscribe keeps itself up to date. It checks once a day, downloads a new version when
there is one, and asks you to restart it to finish. Updates keep your permissions,
and macOS does not ask about malware again. The switch is in the welcome window and
in **Settings → About**; **Check for Updates…** in the menu checks at once.

### The first launch

Nscribe appears in the menu bar as its N, and nowhere else: it joins the Dock and
Command-Tab only while one of its windows is open. A welcome window says what the
key does, then lists what macOS needs to allow, ticking each item off as it is done,
and has a box to try a dictation in before it closes.

<p align="center">
  <img src="Docs/Images/menu.png" width="363"
       alt="Nscribe's menu: Start Dictation, Start Meeting, the rewrite style, the microphone, Meetings, Recent Dictations, Settings and Check for Updates">
</p>

| Permission | Needed for | Asked |
|---|---|---|
| **Microphone** | hearing you | by macOS, the first time you dictate |
| **Speech Recognition** | turning speech into text | by macOS, the first time you dictate |
| **Accessibility** | the dictation key, and typing into other apps | by you, in **System Settings → Privacy & Security → Accessibility** |
| **Screen & System Audio Recording** | hearing the other side of a call, in meetings | by you, in System Settings, only if you switch it on |

Set **System Settings → Keyboard → "Press 🌐 key to"** to *Do Nothing*, or macOS will
also show emoji or switch your input source each time you dictate. The welcome
window checks this setting and says so when it needs changing. The key can be changed in
**Settings → Dictation**.

## Build it yourself

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

Each rebuild is a new app to macOS, and it forgets
the Accessibility grant: remove Nscribe from the Accessibility list and add it
again. The downloaded app keeps one signature from version to version, so its
grants carry over.

## Versions

Versions read like 1.0.352. The first two parts are raised by hand: the second when
something new ships, the first for a change big enough to say so. The third is the
number of commits the app was built from, so it rises with every build, fixes
included, and any two builds can be told apart. **Settings → About** shows it. Releases
are tagged with the whole version, such as `v1.0.352`, and listed under
[Releases](https://github.com/frozenemitt/nscribe/releases).

`Scripts/release.sh` makes a release: it builds and signs the app, puts it in the
disk image, and writes the appcast that tells installed copies about it. The notes
are in [Docs/Releases](Docs/Releases): `whats-new.md`, rewritten for every release
and shown in Software Update and What's New, and the about text for the release
page.

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

## License

MIT. See [LICENSE](LICENSE).

## Acknowledgments

Begun from [Swift Scribe](https://github.com/seamlesscompute/swift-scribe) by
seamlesscompute (MIT). The dictation and meeting features follow
[voxtype](https://github.com/peteonrails/voxtype). Speaker separation is
[FluidAudio](https://github.com/FluidInference/FluidAudio)'s.
