<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="Docs/Images/wordmark-dark.png">
    <img src="Docs/Images/wordmark-light.png" width="320" height="186" alt="Nscribe">
  </picture>
</p>

<h3 align="center">Dictation and meeting notes that never leave your Mac.</h3>

<p align="center">Hold one key, talk, and your words appear wherever you're typing.</p>

<br>

<p align="center">
  <a href="https://github.com/frozenemitt/nscribe/releases/latest/download/Nscribe.dmg">
    <picture>
      <source media="(prefers-color-scheme: dark)" srcset="Docs/Images/download-dark.png">
      <img src="Docs/Images/download-light.png" width="200" height="46" alt="Download for Mac">
    </picture>
  </a>
  <br>
  <sub>Free and open source · No account · macOS 27</sub>
</p>

<br>

<p align="center">
  <img src="Docs/Images/dictation-clip.webp" width="658"
       alt="A dictation into Notes: the ribbon swells blue and violet as the words arrive in the panel, turns amber while they are cleaned up, and the sentence lands in the note">
</p>

## Why Nscribe

- **Every app, one key.** Hold <kbd>Globe</kbd>, talk, let go. Your words appear
  wherever your cursor is.
- **Reads like you typed it.** Built-in cleanup removes the ums, fixes punctuation,
  and can rewrite in the tone you want.
- **Private by design.** Speech recognition, cleanup and speaker detection all run on
  your Mac. Nothing is uploaded.
- **Free, with no catch.** Open source. No account, no subscription, no limits.

## Dictation

- **Hold to talk, or tap to toggle.** Hold <kbd>Globe</kbd> while you speak, or tap it
  once to start and again to stop. <kbd>Esc</kbd> cancels.
- **Works in any app.** Mail, Messages, Slack, your code editor: if it has a text
  field, Nscribe types into it. No text field? Your words go to the clipboard.
- **See every word as you say it.** A floating panel shows your words live, with a
  ribbon of light that moves with your voice.
- **Cleanup in your style.** Choose Clean Up, Simple Clean, Summarize, Make Formal,
  Make Casual or Fix Punctuation, or write your own prompt. Nscribe can read what's
  already in the field, so a reply fits the thread it answers.
- **Learns your words.** Add names and jargon so they're recognized, and set
  replacements for words it keeps getting wrong.
- **A style for every app.** Set casual for Messages and formal for Mail, and Nscribe
  switches on its own.
- **Nothing lost.** <kbd>⌃⌥⌘Z</kbd> takes back the last dictation. <kbd>⌃⌥⌘V</kbd>
  types it again wherever you are now. Recent dictations are kept, so a dictation
  that landed in the wrong window is never gone.

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="Docs/Images/rewriting-dark.png">
    <img src="Docs/Images/rewriting-light.png" width="760"
         alt="Settings, Rewriting: the built-in prompts with their In menu switches, and Simple Clean open for editing, showing its system prompt and its instructions">
  </picture>
  <br>
  <sub>Use the built-in styles, edit them, or write your own.</sub>
</p>

## Meetings

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="Docs/Images/meeting-window-dark.png">
    <img src="Docs/Images/meeting-window-light.png" width="760"
         alt="A meeting in Nscribe: its title, the three speakers, a summary, and the transcript by speaker, with the word being played set in bold">
  </picture>
  <br>
  <sub>Every meeting sorted by speaker, with a summary on top.</sub>
</p>

- **No bot in your call.** Nscribe records your microphone and your Mac's audio, so it
  works with any call app. Nothing joins the meeting.
- **One click to start.** Choose Start Meeting from the menu bar. A small pill shows
  it's recording, with Pause and Stop.
- **Who said what.** When the meeting ends, Nscribe separates the speakers. You name
  each one once.
- **A title and a summary, written for you.** On your Mac, by Apple's on-device model.
- **Click any word to hear it.** Playback follows along word by word. Fix a line by
  typing over it, move it to another speaker, or split it in two.
- **Bring your own recordings.** Import an audio or video file and get the same
  transcript.
- **Take it with you.** Export as Markdown or plain text. Deleted meetings stay in
  Recently Deleted for 30 days.

## Install

1. **Download [Nscribe.dmg](https://github.com/frozenemitt/nscribe/releases/latest/download/Nscribe.dmg)**
   and drag Nscribe into Applications.
2. **Open it.** Nscribe isn't distributed through Apple's paid developer program, so
   the first time, macOS says it can't check the app for malware. Click **Done**,
   open **System Settings → Privacy & Security**, and click **Open Anyway**. You only
   do this once.
3. **Follow the welcome window.** It walks you through each permission and gives you
   a box to try your first dictation.

**Requirements:** macOS 27, with dictation in English. Cleanup, titles and summaries
need Apple Intelligence, which you turn on in **System Settings → Apple Intelligence
& Siri**.

**Updates:** Nscribe keeps itself up to date. It checks once a day and asks you to
restart when a new version is ready. Earlier versions are under
[Releases](https://github.com/frozenemitt/nscribe/releases).

Nscribe lives in your menu bar. It shows up in the Dock only while one of its
windows is open.

<p align="center">
  <img src="Docs/Images/menu.png" width="363"
       alt="Nscribe's menu: Start Dictation, Start Meeting, the rewrite style, the microphone, Meetings, Recent Dictations, Settings and Check for Updates">
</p>

## Privacy

**Your voice and your words stay on your Mac.** Apple's on-device speech recognizer
transcribes, Apple's on-device model writes cleanups and summaries, and speaker
detection runs locally.

Nscribe goes online for three things only, and none of them carries your data:

- **Apple's speech model** downloads the first time you dictate.
- **Update checks** read one small file from GitHub once a day. Every update is
  signed, and Nscribe verifies it before installing. You can turn the daily check off
  in **Settings → About**.
- **Speaker models** download from Hugging Face only when you click **Install
  Models** in **Settings → Meetings**, and are checked against the published hashes.

Recent dictations are saved as plain text on your Mac. You can turn that off.

## FAQ

**Pressing Globe opens the emoji picker or switches my keyboard.**
Set **System Settings → Keyboard → "Press 🌐 key to"** to *Do Nothing*. The welcome
window checks this for you. You can also choose a different key in
**Settings → Dictation**.

**What permissions does Nscribe need?**

| Permission | Why | How it's granted |
|---|---|---|
| **Microphone** | To hear you | macOS asks the first time you dictate |
| **Speech Recognition** | To turn speech into text | macOS asks the first time you dictate |
| **Accessibility** | For the dictation key, and to type into other apps | You turn it on in **System Settings → Privacy & Security → Accessibility** |
| **Screen & System Audio Recording** | To record the other side of a call | You turn it on in System Settings, only if you use it |

**Why isn't Nscribe on the Mac App Store?**
App Store apps must be sandboxed, and macOS never gives a sandboxed app the
Accessibility access Nscribe needs to type into other apps.

## Build from source

Nscribe builds with Xcode 27 and a free Apple ID; no paid developer account is
needed.

```bash
git clone https://github.com/frozenemitt/nscribe.git
cd nscribe
Scripts/install.sh
```

[BUILDING.md](BUILDING.md) covers building in Xcode, versions, releases and how the
code is laid out.

## License

MIT. See [LICENSE](LICENSE).

## Acknowledgments

Begun from [Swift Scribe](https://github.com/seamlesscompute/swift-scribe) by
seamlesscompute (MIT). The dictation and meeting features follow
[voxtype](https://github.com/peteonrails/voxtype). Speaker separation comes from
[FluidAudio](https://github.com/FluidInference/FluidAudio), and updates from
[Sparkle](https://sparkle-project.org).
