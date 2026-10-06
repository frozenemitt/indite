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
  <sub>Free and open source · macOS 27</sub>
</p>

<br>

<p align="center">
  <img src="Docs/Images/dictation-clip.webp" width="658"
       alt="A dictation into Notes: the ribbon swells blue and violet as the words arrive in the panel, turns amber while they are cleaned up, and the sentence lands in the note">
</p>

Nscribe types what you say into any app on your Mac. It runs on Apple's on-device
speech and language models, so it works offline and nothing you say leaves your Mac.

## Dictation

Dictate into any app on your Mac, with a shortcut you choose. Nscribe is made for
replying quickly, to people or to software.

Add your own vocabulary, and Nscribe also listens for the names and unusual words in
the window you're dictating into, so obscure terms come out spelled right. Cleanup
then puts what you said into the style you want. It can remove filler words, make a
message formal or casual, fix the punctuation, or follow a prompt you write, and it
can read the text in the field to match the conversation.

- Watch your words appear as you speak, or hide the panel.
- Give each app its own style.

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="Docs/Images/rewriting-dark.png">
    <img src="Docs/Images/rewriting-light.png" width="760"
         alt="Settings, Rewriting: the built-in prompts with their In menu switches, and Simple Clean open for editing, showing its system prompt and its instructions">
  </picture>
</p>

## Meetings

Record a meeting and stay in the conversation instead of taking notes. Nscribe
records your microphone, and your Mac's audio if you allow it, so it hears both sides
of a call in any app. Nothing joins the call.

When the meeting ends, Nscribe separates the speakers and writes a title and a
summary. Play the transcript back word by word, fix anything it misheard, and export
it as Markdown, ready to hand to an AI for a second look. Recordings and videos can be
imported too.

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="Docs/Images/meeting-window-dark.png">
    <img src="Docs/Images/meeting-window-light.png" width="760"
         alt="A meeting in Nscribe: its title, the three speakers, a summary, and the transcript by speaker, with the word being played set in bold">
  </picture>
</p>

## Privacy

Transcription, cleanup and summaries use Apple's on-device models, and speaker
separation runs on your Mac too. Nscribe works offline, and your audio and text are
never uploaded.

It connects to the internet for three things:

- Apple's speech model, downloaded the first time you dictate.
- A daily update check against this repository's latest release. You can turn it off
  in **Settings → About**. Updates are signed and verified before they install.
- The speaker models, downloaded from Hugging Face when you click **Install Models**
  in **Settings → Meetings**.

## Install

1. Download [Nscribe.dmg](https://github.com/frozenemitt/nscribe/releases/latest/download/Nscribe.dmg)
   and drag Nscribe into Applications.
2. Open it. The first time, macOS says it can't check Nscribe for malware, because
   Nscribe isn't signed through Apple's paid developer program. Click **Done**, then
   open **System Settings → Privacy & Security** and click **Open Anyway**.
3. The welcome window walks you through the permissions and lets you try a dictation.

Nscribe needs macOS 27 and dictates in English. Cleanup, titles and summaries also
need Apple Intelligence, which you turn on in **System Settings → Apple Intelligence
& Siri**. Nscribe updates itself; older versions are under
[Releases](https://github.com/frozenemitt/nscribe/releases).

Nscribe lives in the menu bar.

<p align="center">
  <img src="Docs/Images/menu.png" width="363"
       alt="Nscribe's menu: Start Dictation, Start Meeting, the rewrite style, the microphone, Meetings, Recent Dictations, Settings and Check for Updates">
</p>

## FAQ

**Pressing Globe opens the emoji picker or switches my keyboard.**
Set **System Settings → Keyboard → "Press 🌐 key to"** to *Do Nothing*, or choose a
different key in **Settings → Dictation**.

**What permissions does it need?**

| Permission | What for |
|---|---|
| Microphone | Hearing you |
| Speech Recognition | Turning speech into text |
| Accessibility | The dictation key, and typing into other apps |
| Screen & System Audio Recording | The other side of a call, only if you record meetings with it |

**Why isn't it on the Mac App Store?**
App Store apps have to be sandboxed, and macOS doesn't give a sandboxed app the
Accessibility access it needs to type into other apps.

## Build from source

You need Xcode 27 and a free Apple ID.

```bash
git clone https://github.com/frozenemitt/nscribe.git
cd nscribe
Scripts/install.sh
```

See [BUILDING.md](BUILDING.md) for building in Xcode, versions, releases and the code
layout.

## License

MIT. See [LICENSE](LICENSE).

## Acknowledgments

Built on [Swift Scribe](https://github.com/seamlesscompute/swift-scribe) by
seamlesscompute (MIT). The dictation and meeting features follow
[voxtype](https://github.com/peteonrails/voxtype). Speaker separation uses
[FluidAudio](https://github.com/FluidInference/FluidAudio), and updates use
[Sparkle](https://sparkle-project.org).
