<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="Docs/Images/wordmark-dark.png">
    <img src="Docs/Images/wordmark-light.png" width="320" height="186" alt="Nscribe">
  </picture>
</p>

<h3 align="center">Unlock the potential of Apple's Foundation Models.</h3>

<p align="center">Fast, free, on-device dictation and transcription that knows your context and adapts to your prompts.</p>

<br>

<p align="center">
  <a href="https://github.com/frozenemitt/nscribe/releases/latest/download/Nscribe.dmg">
    <picture>
      <source media="(prefers-color-scheme: dark)" srcset="Docs/Images/download-dark.png">
      <img src="Docs/Images/download-light.png" width="200" height="46" alt="Download for Mac">
    </picture>
  </a>
  <br>
  <sub>Open source · macOS 27 · English</sub>
</p>

<br>

<p align="center">
  <img src="Docs/Images/dictation-clip.webp" width="658"
       alt="A dictation into Notes: the ribbon swells blue and violet as the words arrive in the panel, turns amber while they are cleaned up, and the sentence lands in the note">
</p>

Nscribe types what you say into any app on your Mac and transcribes your meetings.
It runs on Apple's speech recognition and on Apple's Foundation Models, the models
behind Apple Intelligence, all on your Mac.

## Dictation

Nscribe is made for replying quickly, to people or to software.

Once you've added a few words of your own, Nscribe also reads the names and unusual
words in the window you're dictating into, so when you say them they come out spelled
right.

Rewriting then puts what you said into the style you want, formal in Mail and casual
in Messages, with each app keeping its own. Every style is a plain-English prompt you
can edit, or write from scratch. Rewriting can also read what's already in the text
field, so your answer fits the thread.

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="Docs/Images/rewriting-dark.png">
    <img src="Docs/Images/rewriting-light.png" width="760"
         alt="Settings, Rewriting: the built-in prompts with their In menu switches, and Simple Clean open for editing, showing its system prompt and its instructions">
  </picture>
</p>

## Meetings

Record a meeting and stay in the conversation instead of taking notes. Nscribe records
your microphone and, if you allow it, the sound your Mac plays, so it hears both sides
of a call in any app. Nobody else has to install anything.

When the meeting ends, Nscribe works out who said what and writes a title and a
summary. Play the recording and follow each word as it's spoken, fix what it misheard,
and export the transcript as Markdown to ask an AI what was decided. It can also
transcribe a recording or video you already have.

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="Docs/Images/meeting-window-dark.png">
    <img src="Docs/Images/meeting-window-light.png" width="760"
         alt="A meeting in Nscribe: its title, the three speakers, a summary, and the transcript by speaker, with the word being played set in bold">
  </picture>
</p>

## Privacy

Your audio and text are never uploaded. Nscribe connects to the internet for three
things only:

- Apple's English speech recognition, which macOS downloads the first time you
  dictate.
- A daily check for a new version of Nscribe, which you can turn off. Each update is
  checked against Nscribe's own signature before it installs.
- The files that tell voices apart, downloaded from Hugging Face when you install
  them for meetings.

To spell names right, Nscribe reads the text of the window you're dictating into,
keeps only the unusual words for that one dictation, and stores nothing. Your last 100
dictations and your meeting recordings stay on your Mac, and both can be turned off.
The source is open, so all of this can be checked.

## Install

Nscribe needs macOS 27 and dictates in English. Rewriting and meeting summaries need
Apple Intelligence turned on.

1. Download [Nscribe](https://github.com/frozenemitt/nscribe/releases/latest/download/Nscribe.dmg)
   and drag it into Applications.
2. Open it. The first time, macOS warns that it can't check Nscribe for malware. Apple
   checks only apps from its paid developer program, and Nscribe, a free project,
   isn't in it. Click **Done**, then open **System Settings → Privacy & Security** and
   click **Open Anyway**.
3. Nscribe opens in the menu bar, and its welcome window sets up the permissions with
   you.

<p align="center">
  <img src="Docs/Images/menu.png" width="363"
       alt="Nscribe's menu: Start Dictation, Start Meeting, the rewrite style, the microphone, Meetings, Recent Dictations, Settings and Check for Updates">
</p>

## FAQ

**The Globe key (🌐) opens the emoji picker instead of dictating.**
In System Settings → Keyboard, set "Press 🌐 key to" to *Do Nothing*, or choose a
different key in Nscribe's settings.

**What permissions does it need?**

| Permission | What for |
|---|---|
| Microphone | Hearing you |
| Speech Recognition | Turning speech into text |
| Accessibility | Typing into other apps, and reading the window you dictate into. macOS files both under Accessibility. |
| Screen & System Audio Recording | Hearing the other side of a call, if you turn that on. Nscribe takes only the sound. |

**Why isn't it on the Mac App Store?**
App Store apps have to be sandboxed, and a sandboxed app can't type into other apps.

## Build from source

For developers: you need Xcode 27 and a free Apple ID.

```bash
git clone https://github.com/frozenemitt/nscribe.git
cd nscribe
Scripts/install.sh
```

See [BUILDING.md](BUILDING.md) for Xcode builds, releases and the code layout.

## License

[MIT License](LICENSE).

## Acknowledgments

Built on [Swift Scribe](https://github.com/seamlesscompute/swift-scribe) by
seamlesscompute (MIT). The dictation and meeting features are modeled on
[voxtype](https://github.com/peteonrails/voxtype). Speaker separation uses
[FluidAudio](https://github.com/FluidInference/FluidAudio), and updates use
[Sparkle](https://sparkle-project.org).
