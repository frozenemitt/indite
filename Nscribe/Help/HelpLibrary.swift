import Foundation

/// The help articles: one task or one question each. See `Docs/help-and-siri.md`.
///
/// The Help window lists them in this order, which is the order of the topics. The
/// assistant finds them by the words they share with a question, so each one names
/// the settings exactly as the app shows them and uses the words people ask with.
enum HelpLibrary {
    static let articles: [HelpArticle] = [
        // Getting Started
        firstDictation, menuBar, openAnyway, askNscribe, updates,
        // Dictation
        dictationKey, handsFree, cancelDictation, dictationPanel, afterTyping, alwaysCopy,
        microphone, stopsByItself, undoDictation, typeAgain, recentDictations, sounds,
        notifications, appProfiles, language,
        // Rewriting
        keepMyWords, choosePrompt, customPrompt, promptAdvanced, surroundingContext,
        // Words and Spelling
        vocabulary, wordReplacements,
        // Meetings
        startMeeting, callAudio, meetingPill, speakerNames, oldMeetingSpeakers, correctTranscript, playback,
        meetingSummary, importRecording, exportMeeting, deleteMeeting, searchMeetings,
        // Siri and Shortcuts
        quickTranscribe, siriHelp,
        // Privacy and Permissions
        permissions, privacy, storedData,
        // Troubleshooting
        globeKeyEmoji, keyDoesNothing, nothingHeard, copiedNotTyped, appleIntelligence,
        rewriteFailed, callAudioSilent, noSpeakerNames, microphoneBusy, diagnostics,
        resetSettings
    ]

    // MARK: - Getting Started

    static let firstDictation = HelpArticle(
        id: "first-dictation",
        title: "Dictate into any app",
        body: """
            Click where you want the text, such as in an email or a document. Then hold \
            the Globe key (🌐), say what you want to write, and let go. Your words show up \
            where the cursor is, in whichever app is in front.

            While you talk, a panel near the bottom of the screen shows the words as they \
            arrive. Nscribe starts listening when the start sound plays. You can also \
            click Nscribe's N in the menu bar and choose "Start Dictation", then "Stop \
            Dictation" when you are done.

            The first time you dictate, macOS asks you to allow the microphone and speech \
            recognition. The dictation key also needs Accessibility access, which you \
            allow in System Settings, under Privacy & Security, then Accessibility.
            """,
        topic: .gettingStarted
    )

    static let menuBar = HelpArticle(
        id: "menu-bar",
        title: "Find Nscribe in the menu bar",
        body: """
            If you can't find Nscribe after opening it, look for its N in the menu bar at \
            the top of the screen. The app opens no window of its own and has no Dock \
            icon: it joins the Dock and Command-Tab only while one of its windows is open.

            Click the N to open Nscribe's menu. Its first line says whether Nscribe is \
            ready and which key starts a dictation. Below it are "Start Dictation", "Start \
            Meeting", the Rewrite and Microphone choices, "Meetings", "Recent Dictations", \
            "Help", "Settings…" and "Check for Updates…".

            The N changes shape with what Nscribe is doing. It sits in a filled square \
            while you dictate, becomes a brain while your words are rewritten, and becomes \
            a record circle with the meeting's clock beside it during a meeting. A warning \
            triangle means the dictation key is not working.
            """,
        topic: .gettingStarted
    )

    static let openAnyway = HelpArticle(
        id: "open-anyway",
        title: "macOS can't check Nscribe for malware",
        body: """
            The first time you open Nscribe, macOS says it cannot check Nscribe for \
            malware, and offers only Done and Move to Trash. Click Done. Then open System \
            Settings, choose Privacy & Security, and click "Open Anyway" next to the line \
            about Nscribe. macOS asks for your password once, and Nscribe opens.

            macOS shows this warning because Nscribe is free and is not signed through \
            Apple's paid developer program, which is what that check looks for. Updates \
            that Nscribe installs itself do not bring the warning back.
            """,
        topic: .gettingStarted
    )

    static let askNscribe = HelpArticle(
        id: "ask-nscribe",
        title: "Ask Nscribe a question",
        body: """
            Click Nscribe's N in the menu bar and choose "Help", or choose "Nscribe Help" \
            from the Help menu while an Nscribe window is open. Type a question, or \
            describe what isn't working, and press Return.

            The answer is written on this Mac by Apple's on-device model, from these help \
            articles. Under it, "From" names the article it came from, and a button opens \
            the setting it mentions when there is one.

            Answers need Apple Intelligence. Without it, click "Browse all articles" to \
            read the articles by topic.
            """,
        topic: .gettingStarted
    )

    static let updates = HelpArticle(
        id: "updates",
        title: "Update Nscribe",
        body: """
            Nscribe keeps itself up to date. Once a day it checks the latest release on \
            GitHub, downloads a new version when there is one, and sends a notification \
            when it is ready. Click the notification, or choose "Restart to Install \
            Nscribe" at the top of Nscribe's menu, to finish. If you are recording at the \
            time, Nscribe waits and restarts when the recording ends.

            To check at once, choose "Check for Updates…" from the menu. To stop the daily \
            check and download, open Nscribe's Settings, choose About, and turn off \
            "Update automatically".

            Nscribe checks each update's signature before installing it. Updates keep your \
            permissions, and macOS does not show its malware warning again.
            """,
        topic: .gettingStarted
    )

    // MARK: - Dictation

    static let dictationKey = HelpArticle(
        id: "dictation-key",
        title: "Change the dictation key",
        body: """
            You start talking to Nscribe by pressing the Globe key (🌐). You can use a key \
            combination instead, such as Control-Option-D (⌃⌥D).

            Open Nscribe's Settings, choose Dictation, and turn off "Use the Globe key". \
            Click the button beside "Key combination", then press the shortcut you want. A \
            shortcut needs a letter, number or punctuation key and at least two of Control \
            (⌃), Option (⌥) and Command (⌘), so it cannot take over an everyday one like \
            ⌘W. Press Escape instead to keep the key you had. The combination starts out \
            as ⌃⌥⌘C.

            The first line of Nscribe's menu names the key in use.
            """,
        topic: .dictation,
        action: .nscribeSettings(.dictation)
    )

    static let handsFree = HelpArticle(
        id: "hands-free",
        title: "Dictate without holding the key down",
        body: """
            Open Nscribe's Settings, choose Dictation, and under "Pressing it" choose \
            "Press to start, press to stop". Press the dictation key once to start, talk \
            with your hands free, and press it again to stop.

            "Hold to talk", the default, listens only while you hold the key down and \
            stops when you let go.

            In either mode, Escape throws the dictation away.
            """,
        topic: .dictation,
        action: .nscribeSettings(.dictation)
    )

    static let cancelDictation = HelpArticle(
        id: "cancel-dictation",
        title: "Cancel a dictation",
        body: """
            To throw away a dictation before it is typed, such as one you started by \
            mistake, press Escape while Nscribe is listening. Nothing is typed or copied.

            To end a dictation and keep the words, let go of the dictation key, or press \
            it again if you chose "Press to start, press to stop". You can also click \
            Nscribe's N in the menu bar and choose "Stop Dictation".

            If the words have already been typed, press Control-Option-Command-Z (⌃⌥⌘Z) \
            within two minutes to take them back.
            """,
        topic: .dictation
    )

    static let dictationPanel = HelpArticle(
        id: "dictation-panel",
        title: "Move, fade or hide the dictation panel",
        body: """
            The dictation panel is the floating box that shows your words while Nscribe \
            hears them. Its ribbon moves blue and violet with your voice, turns amber \
            while the words are rewritten, and the panel then says how the dictation \
            ended.

            If the panel covers what you are reading, drag it anywhere, and it comes back \
            where you left it. To change how see-through it is, open Nscribe's Settings, \
            choose Feedback, and move the "Glass" and "Words and ribbon" sliders. "Reset \
            Panel Positions" puts it back at the bottom of the screen. To make the panel \
            go away for good, turn off "Show the words as you dictate".
            """,
        topic: .dictation,
        action: .nscribeSettings(.feedback)
    )

    static let afterTyping = HelpArticle(
        id: "after-typing",
        title: "Press Return or add a space after the words",
        body: """
            Nscribe can press a key after it types your words. Open Nscribe's Settings, \
            choose Dictation, and under "Where the Text Goes" set "After typing".

            "Add a space" lets your next dictation carry on the sentence. "Press Return" \
            hits Enter for you, which sends the message in a chat app such as Slack or \
            Messages. "Press Shift-Return" starts a new line and leaves the message \
            unsent. "Nothing" is the default. If your messages are being sent \
            automatically, choose "Nothing" or "Press Shift-Return" to stop it.

            To press Return in one app only, add a profile for that app in the Apps tab \
            and set "Press Return after typing" to Yes. Once Return has been pressed, the \
            undo key cannot take the dictation back.
            """,
        topic: .dictation,
        action: .nscribeSettings(.dictation)
    )

    static let alwaysCopy = HelpArticle(
        id: "always-copy",
        title: "Copy dictations instead of typing them",
        body: """
            Open Nscribe's Settings, choose Dictation, and under "After transcribing" \
            choose "Always copy to the clipboard". Each dictation then goes to the \
            clipboard, and you paste it with Command-V (⌘V) wherever you want it.

            The default, "Type into the focused field, otherwise copy", types the words \
            where the cursor is. Nscribe types by pasting, so it borrows the clipboard for \
            a moment. "Restore my previous clipboard afterwards", on by default, puts back \
            the text you had copied before. If Nscribe wipes what you had copied, check \
            that this switch is on.

            To copy instead of type in one app only, add a profile for that app in the \
            Apps tab and set its "Output".
            """,
        topic: .dictation,
        action: .nscribeSettings(.dictation)
    )

    static let microphone = HelpArticle(
        id: "microphone",
        title: "Choose the microphone",
        body: """
            To switch the microphone Nscribe uses for recording, such as to AirPods or a \
            headset, click Nscribe's N in the menu bar, open the Microphone menu, and \
            choose it. Dictations and meetings both record from it. The same choice is in \
            Nscribe's Settings, under Dictation, as "Record from".

            If your microphone isn't picking anything up, the wrong one may be chosen: \
            check the Microphone menu first. "System Default" follows the Mac's own \
            default input. If the microphone you \
            chose is unplugged, Nscribe records from the system default, and the menu says \
            the chosen one is "Not Connected".
            """,
        topic: .dictation
    )

    static let stopsByItself = HelpArticle(
        id: "stops-by-itself",
        title: "A long dictation stopped by itself",
        body: """
            Nscribe stops a dictation after 10 minutes, so a key that sticks cannot record \
            for ever. The words up to that point are typed as usual.

            To dictate for longer, open Nscribe's Settings, choose Dictation, and under \
            Microphone set "Stop by itself after" to a longer time, up to an hour. The \
            limit applies to dictations only. For a talk or a long conversation, choose \
            "Start Meeting" from Nscribe's menu instead.
            """,
        topic: .dictation,
        action: .nscribeSettings(.dictation)
    )

    static let undoDictation = HelpArticle(
        id: "undo-dictation",
        title: "Take back the last dictation",
        body: """
            Press Control-Option-Command-Z (⌃⌥⌘Z) within two minutes of a dictation being \
            typed. Nscribe sends Undo to the app that received the words, so they come out \
            again. It also puts them on the clipboard, in case you still want them.

            The undo key does not work once "After typing" has pressed Return or \
            Shift-Return, because the message may already be sent.

            To change the key or switch it off, open Nscribe's Settings, choose Dictation, \
            and look under "Undo Key" for "Take back the last dictation with a key".
            """,
        topic: .dictation
    )

    static let typeAgain = HelpArticle(
        id: "type-again",
        title: "Put a dictation where it belongs",
        body: """
            If Nscribe typed a dictation into the wrong window, or nowhere, click the \
            right place for the text and press Control-Option-Command-V (⌃⌥⌘V). Nscribe \
            types the last dictation again at the cursor, with no rewrite and no Return \
            after it.

            For an earlier one, click Nscribe's N in the menu bar and open "Recent \
            Dictations", which lists the last five. Click one to type it at the cursor, or \
            Option-click it to copy it.

            Both need "Keep recent dictations", which is on unless you turned it off. To \
            change the key, open Nscribe's Settings, choose Dictation, and look under \
            "Type-Again Key".
            """,
        topic: .dictation
    )

    static let recentDictations = HelpArticle(
        id: "recent-dictations",
        title: "Find an earlier dictation",
        body: """
            Nscribe keeps your last 100 dictations, so you can find an old one later. \
            Click the N in the menu bar, open "Recent Dictations", and choose "Show All" \
            to see them in a window you can search.

            Select a dictation and click "Copy", or click the "Insert into" button, which \
            names the app you came from, to type it where the cursor is in that app. When \
            the words were rewritten, "Copy Original" in the More menu copies them as they \
            were heard. "Clear All…" deletes every dictation.

            To keep more or fewer, open Nscribe's Settings, choose Dictation, and change \
            "Keep the last" under "Recent Dictations".
            """,
        topic: .dictation
    )

    static let sounds = HelpArticle(
        id: "sounds",
        title: "Change or turn off the sounds",
        body: """
            To stop the sound Nscribe makes when you start talking, or any of its other \
            beeps and chimes, open Nscribe's Settings and choose Feedback. Turn off "Play \
            sounds" to silence them all. To change one, pick another sound beside \
            "Recording started", "Recording stopped", "While rewriting", "Text delivered" \
            or "Something went wrong", or choose None to silence only that one. The \
            "Preview Sound" button beside each one plays it.

            To use a sound of your own, click "Import Sound File…" under "Your Sounds" and \
            choose an audio file. It then appears in every list of sounds.
            """,
        topic: .dictation,
        action: .nscribeSettings(.feedback)
    )

    static let notifications = HelpArticle(
        id: "notifications",
        title: "Turn off Nscribe's notifications",
        body: """
            Open Nscribe's Settings, choose Feedback, and look under Notifications. Turn \
            off "When a dictation has been delivered" to stop the banner after every \
            dictation. Turn off "When something goes wrong" to stop the banners that \
            explain a failure, such as a rewrite that did not finish. Both are on until \
            you turn them off.
            """,
        topic: .dictation,
        action: .nscribeSettings(.feedback)
    )

    static let appProfiles = HelpArticle(
        id: "app-profiles",
        title: "Set different rules for one app",
        body: """
            A profile changes how dictation behaves in one app, so Terminal and Mail, for \
            example, can each work their own way. Open Nscribe's Settings, choose Apps, \
            click "Add App…", and choose the app.

            A profile can set its own "Prompt", including Off to skip rewriting in that \
            app. It can set its own "Output", to type or always copy, and whether to \
            "Press Return after typing". "Use the default" keeps your general setting. The \
            switch beside the app's name turns the profile off without deleting it, and \
            "Remove Profile" deletes it.

            The app you start talking in picks the prompt. The app in front when the text \
            is ready decides how it arrives. When the app in front has a prompt of its \
            own, Nscribe's menu says so.
            """,
        topic: .dictation,
        action: .nscribeSettings(.apps)
    )

    static let language = HelpArticle(
        id: "language",
        title: "Dictate in another language",
        body: """
            Nscribe has no language setting of its own: it transcribes in your Mac's \
            language. It takes the first language under Preferred Languages, in System \
            Settings, General, Language & Region, that Apple's speech recognizer \
            supports, such as German, Spanish, French, Italian, Portuguese, Japanese, \
            Korean, Chinese or Hindi. If it supports none of them, Nscribe transcribes US \
            English. Dictation, meetings and imported recordings all use that one \
            language.

            To dictate in another language, or to switch between two, drag the one you \
            want to the top of Preferred Languages. Then choose "Quit Nscribe" from \
            Nscribe's menu and open Nscribe again: it picks its language when it opens. \
            It hears one language at a time, so it cannot follow a dictation that mixes \
            two. Apple downloads the speech model for a \
            language the first time you dictate in it, so that first dictation can take \
            longer to start.

            Where Apple has a version of the language for your region, such as Swiss \
            German or Canadian French, Nscribe uses it. Otherwise it uses the language's \
            home version: German on a Mac set to the United States is Germany's German.

            Rewriting keeps your dictation in the language you spoke, and does not \
            translate it. Apple Intelligence, which does the rewriting, does not support \
            Hindi or the other languages of India.
            """,
        topic: .dictation
    )

    // MARK: - Rewriting

    static let keepMyWords = HelpArticle(
        id: "keep-my-words",
        title: "Stop Nscribe changing your words",
        body: """
            Nscribe rewrites each dictation with the Clean Up prompt unless you choose \
            another. Clean Up removes filler words and rephrases unclear sentences. If it \
            keeps rephrasing or rewording what you say, and you want your exact words, \
            click the N in the menu bar, open the Rewrite menu, and choose Off.

            To keep your words but still fix mistakes, choose Simple Clean instead. It \
            fixes only misheard words, repeated words and punctuation, and it puts back \
            any word the model drops. Fix Punctuation adds punctuation and capitals \
            without changing a word.

            The same choice is in Nscribe's Settings, under Rewriting, as "Rewrite \
            dictations" and "With".
            """,
        topic: .rewriting
    )

    static let choosePrompt = HelpArticle(
        id: "choose-prompt",
        title: "Choose how dictations are rewritten",
        body: """
            Click Nscribe's N in the menu bar, open the Rewrite menu, and choose a prompt. \
            The built-in prompts are Clean Up, Simple Clean, Summarize, Make Formal, Make \
            Casual and Fix Punctuation. To make a dictation sound more formal, choose Make \
            Formal. Summarize turns what you said into a short bulleted list. Off types \
            the words as they were heard.

            Rewriting runs on this Mac with Apple's on-device model, so it needs Apple \
            Intelligence.

            To shorten the menu, open Nscribe's Settings, choose Rewriting, and turn off \
            the "In menu" switch beside each prompt you never use. "Edit Prompts…" at the \
            foot of the Rewrite menu opens the same place.
            """,
        topic: .rewriting
    )

    static let customPrompt = HelpArticle(
        id: "custom-prompt",
        title: "Write your own rewriting prompt",
        body: """
            To create a new prompt of your own, for a style no built-in prompt covers, \
            open Nscribe's Settings, choose Rewriting, and click "Add Prompt", the plus \
            button under the list. Give the prompt a name. Under "System Prompt", say who \
            the model should be. Under "User Template", say what it should do; your \
            dictation is added after those instructions. Changes are saved as you type.

            Turn on "Keep my words" for a prompt that corrects rather than rewords: any \
            word the model drops is put back. Built-in prompts cannot be edited, so to \
            start from one, select it and click "Duplicate as Custom Prompt". Your prompt \
            then appears in the Rewrite menu.
            """,
        topic: .rewriting,
        action: .nscribeSettings(.rewriting)
    )

    static let promptAdvanced = HelpArticle(
        id: "prompt-advanced",
        title: "Make rewrites more predictable or more varied",
        body: """
            Each prompt has Advanced settings, which set how freely Apple's on-device \
            model chooses its words when it rewrites a dictation. Open Nscribe's \
            Settings, choose Rewriting, select the prompt, and click "Advanced" under its \
            instructions. Built-in prompts can change these too, without a copy.

            Temperature, from 0 to 1, sets how much the wording varies. Lower it to make \
            rewrites more predictable; raise it if they sound stiff or repetitive. Every \
            built-in prompt starts at 0.5, except Simple Clean, which starts at 0.3.

            Sampling sets how each word is chosen. Greedy always takes the likeliest word, \
            so the same dictation is rewritten the same way every time: choose it if a \
            prompt rewrites the same words differently each time, or strays from what you \
            said. Simple Clean uses it. Temperature is hidden while Greedy is chosen, \
            because it has nothing to act on. Automatic, the setting for the other \
            built-in prompts, is Apple's default. Top-P chooses among the likeliest words \
            until their chances add up to the Probability Threshold. Top-K chooses among a \
            fixed number of the likeliest words; a lower Top K keeps the wording closer.
            """,
        topic: .rewriting,
        action: .nscribeSettings(.rewriting)
    )

    static let surroundingContext = HelpArticle(
        id: "surrounding-context",
        title: "Let the rewrite match the conversation",
        body: """
            Open Nscribe's Settings, choose Rewriting, select Options, and turn on "Let \
            the AI see what is already in the field". When you dictate a reply, the model \
            then reads the text around your cursor, such as the email or thread you are \
            replying to, so the rewrite takes it into account.

            It is off by default, and it works only while "Rewrite dictations" is on. \
            Nscribe reads the text through the Accessibility access it already has, uses \
            it for that one rewrite, and never sends it anywhere.
            """,
        topic: .rewriting,
        action: .nscribeSettings(.rewriting)
    )

    // MARK: - Words and Spelling

    static let vocabulary = HelpArticle(
        id: "vocabulary",
        title: "Teach Nscribe names and jargon",
        body: """
            To teach Nscribe a name it misspells, such as a colleague's name, or to add a \
            word to its dictionary, open Nscribe's Settings, choose Words, and type it \
            under Vocabulary. Put each name \
            or term on a line of its own. When Nscribe is unsure what it heard, it prefers \
            these words, and it spells them the way you wrote them. Dictations and \
            meetings both use the list.

            While the list holds at least one word, Nscribe also listens for unusual names \
            shown in the window you are dictating into, such as the names in an email \
            thread. It reads them for that dictation only and keeps nothing.

            For a word Nscribe gets wrong every time, add a rule under "Word Replacements" \
            on the same tab.
            """,
        topic: .words,
        action: .nscribeSettings(.words)
    )

    static let wordReplacements = HelpArticle(
        id: "word-replacements",
        title: "Fix a word Nscribe always gets wrong",
        body: """
            A word replacement makes Nscribe write one word as another every time you say \
            it. Open Nscribe's Settings, choose Words, and click the plus button under \
            "Word Replacements". Type what Nscribe writes under Heard, such as "gonna", \
            and what you want instead under Written, such as "going to". Every dictation \
            is then corrected before it is rewritten or typed.

            Replacements match whole words only and ignore capitals, so a rule for "vox" \
            leaves "voxel" alone. Leave Written empty to delete the heard word wherever it \
            appears. To remove a rule, select it and click the minus button.
            """,
        topic: .words,
        action: .nscribeSettings(.words)
    )

    // MARK: - Meetings

    static let startMeeting = HelpArticle(
        id: "start-meeting",
        title: "Record a meeting",
        body: """
            Click Nscribe's N in the menu bar and choose "Start Meeting". Nscribe starts \
            recording without opening a window. A small pill shows the meeting's clock \
            with Pause and Stop, and the menu bar shows the clock beside the N.

            To end the meeting, click Stop in the pill and then End, or choose "End \
            Meeting", then "End and Save", from the menu. Nscribe then separates the \
            speakers, if the speaker models are installed, and writes a title and a \
            summary. The meeting appears in the Meetings window, where the red "New \
            Meeting" button (⌘N) starts one too.

            A meeting holds the microphone, so dictation waits until you pause or end it.
            """,
        topic: .meetings
    )

    static let callAudio = HelpArticle(
        id: "call-audio",
        title: "Record both sides of a call",
        body: """
            A meeting records your microphone. To record the other people on a call as \
            well, open Nscribe's Settings, choose Meetings, and turn on "Record system \
            audio, for the other side of a call". Then click "Allow Nscribe in Screen & \
            System Audio Recording…" and turn Nscribe on in the list macOS shows. Nscribe \
            takes only the sound.

            This works with any app that plays the call through your Mac, such as Zoom, \
            Teams or FaceTime. It records every person audible on the call, so check that \
            the people you are meeting with are content to be recorded.
            """,
        topic: .meetings,
        action: .nscribeSettings(.meetings)
    )

    static let meetingPill = HelpArticle(
        id: "meeting-pill",
        title: "Move or hide the meeting pill",
        body: """
            The meeting pill is the small floating panel with a timer that appears during \
            a meeting, on every desktop and over full-screen apps. Its ribbon moves with \
            what the microphone hears, so you can see the meeting is still listening. It \
            also shows the clock, a Pause button and a Stop button. Stop asks "End \
            meeting?" before it ends anything.

            If the pill is in the way, drag it anywhere, and it comes back where you left \
            it. To hide it, open Nscribe's Settings, choose Meetings, and turn off "Show \
            the meeting pill". "Reset Panel Positions" in the Feedback tab puts it back \
            where it started.
            """,
        topic: .meetings,
        action: .nscribeSettings(.meetings)
    )

    static let speakerNames = HelpArticle(
        id: "speaker-names",
        title: "Name the speakers in a meeting",
        body: """
            To change a speaker's label to the person's name, open the meeting in the \
            Meetings window. Each speaker appears as a button under the title, called \
            Speaker 1, Speaker 2 and so on. Click one, type the name, and press Return. \
            The name replaces the label everywhere in the transcript.

            When Nscribe took one person for two, click one of them, choose "Merge Into", \
            and pick the other. Their lines join under one name.

            Nscribe separates the speakers when a meeting ends, and only when the speaker \
            models are installed in Settings, under Meetings.
            """,
        topic: .meetings
    )

    static let oldMeetingSpeakers = HelpArticle(
        id: "old-meeting-speakers",
        title: "Separate the speakers in an earlier meeting",
        body: """
            Nscribe cannot separate the speakers of a meeting recorded before the speaker \
            models were installed. Installing the models later does not change that \
            meeting: speakers are separated only when a meeting ends, and only if the \
            models were installed when it began. Meetings recorded after you install them \
            are separated.

            To give an earlier meeting's lines to other people by hand, open it in the \
            Meetings window, click the speaker's name on a line, and under "Attribute to" \
            choose "A New Speaker" or another speaker.
            """,
        topic: .meetings
    )

    static let correctTranscript = HelpArticle(
        id: "correct-transcript",
        title: "Correct a meeting's transcript",
        body: """
            Click into the transcript and type over any word that is wrong. Your \
            correction is kept. The names and times between lines cannot be edited.

            When a line belongs to someone else, click the speaker's name on that line, \
            and under "Attribute to" choose who said it, or "A New Speaker". When the \
            words of two people ended up in one line, right-click the word where the \
            second person starts, choose "Split Line Here, Rest to", and pick who said the \
            rest.

            Press Command-F (⌘F) to find a word in the meeting.
            """,
        topic: .meetings
    )

    static let playback = HelpArticle(
        id: "playback",
        title: "Play back a meeting",
        body: """
            To listen to a meeting again, or to one part of it, open the meeting in the \
            Meetings window and click any word in the transcript to move the playhead \
            there. Then click Play, or press Command-Return (⌘↩). The word being said is \
            set in bold as the audio runs.

            The bar at the bottom also skips back or forward 15 seconds, and its speed \
            menu plays at 1×, 1.25×, 1.5× or 2×.

            Playback needs the meeting's recording. Nscribe keeps it unless you turn off \
            "Keep the recording after a meeting ends" in Settings, under Meetings. A \
            recording takes about 30 MB of disk space an hour.
            """,
        topic: .meetings
    )

    static let meetingSummary = HelpArticle(
        id: "meeting-summary",
        title: "Get a title and summary for a meeting",
        body: """
            When a meeting or a recorded call ends, Nscribe writes a title and a summary \
            for it on this Mac, with Apple's on-device model. The summary sits above the \
            transcript, folded to its first three points; click "Show all" to read the \
            rest. To write it again, click the arrow beside Summary. A meeting with no \
            summary has a "Summarize" button. Meetings shorter than about a minute are not \
            summarized by themselves.

            This needs Apple Intelligence. Without it, the title is the meeting's opening \
            words. To rename a meeting, click its title and type a new one. To stop titles \
            and summaries being written, open Nscribe's Settings, choose Meetings, and \
            turn off "Write a title and a summary".
            """,
        topic: .meetings
    )

    static let importRecording = HelpArticle(
        id: "import-recording",
        title: "Transcribe a recording or video",
        body: """
            Open the Meetings window from Nscribe's menu, click "Import Recording…" (⌘O), \
            and choose an audio or video file. You can also drag the file onto the list of \
            meetings.

            Nscribe transcribes it on this Mac, separates the speakers when the speaker \
            models are installed, and keeps the audio beside the transcript so you can \
            play it back. Its progress shows as a row in the list, where the finished \
            meeting then appears.
            """,
        topic: .meetings
    )

    static let exportMeeting = HelpArticle(
        id: "export-meeting",
        title: "Export or copy a meeting",
        body: """
            Open the meeting and click "Copy as Markdown" to copy its title, summary and \
            transcript, ready to paste into notes or an email. To save a file, click \
            Export and choose "Save as Markdown…" or "Save as Plain Text…". "Copy as Plain \
            Text", in the same menu, copies it without Markdown.

            To copy only part of a transcript, select the words you want and press \
            Command-C (⌘C). A selection can run across several speakers.
            """,
        topic: .meetings
    )

    static let deleteMeeting = HelpArticle(
        id: "delete-meeting",
        title: "Delete or recover a meeting",
        body: """
            Select a meeting in the Meetings window and press Delete, or click the trash \
            button. Deleted meetings wait 30 days in Recently Deleted, at the foot of the \
            list, and are then erased with their recordings.

            To get back a meeting you deleted by accident, open Recently Deleted, select \
            it, and click "Recover". "Delete Now" erases it at once, with its transcript, \
            summary and recording, and that cannot be undone.
            """,
        topic: .meetings
    )

    static let searchMeetings = HelpArticle(
        id: "search-meetings",
        title: "Find something said in a meeting",
        body: """
            Open the Meetings window and type in the Search field above the list of \
            meetings. The list keeps only the meetings whose title or transcript contains \
            your words, and a meeting you open from it starts at the first place they were \
            said.

            Inside an open meeting, press Command-F (⌘F) to find a word in its transcript.
            """,
        topic: .meetings
    )

    // MARK: - Siri and Shortcuts

    static let quickTranscribe = HelpArticle(
        id: "quick-transcribe",
        title: "Transcribe with Siri or the Shortcuts app",
        body: """
            To use Nscribe from Siri, say "Transcribe with Nscribe". To use it from the \
            Shortcuts app, add Nscribe's "Quick Transcribe" action to a shortcut. It \
            records for 15 seconds unless you set another "Duration", from 5 to 300 \
            seconds, and returns the text.

            In Shortcuts you can choose an "AI Prompt" to rewrite the words, and turn off \
            "Copy to Clipboard", which is on by default. The action uses the same \
            microphone, vocabulary and word replacements as dictation, and its result is \
            kept in Recent Dictations.
            """,
        topic: .siri
    )

    static let siriHelp = HelpArticle(
        id: "siri-help",
        title: "Ask Siri for help with Nscribe",
        body: """
            Say "Ask Nscribe" or "Show Nscribe help" to Siri to open Nscribe's Help \
            window, then type your question. To ask in one go, say "Search Nscribe for" \
            and the question, such as "Search Nscribe for how to change the dictation \
            key". The Help window opens with the answer.

            Spotlight also finds these help articles by their words. Choosing one opens it \
            in Nscribe's Help window.
            """,
        topic: .siri
    )

    // MARK: - Privacy and Permissions

    static let permissions = HelpArticle(
        id: "permissions",
        title: "The permissions Nscribe needs",
        body: """
            Nscribe needs four permissions from macOS. Microphone and Speech Recognition \
            let it hear and transcribe you, and macOS asks for both the first time you \
            dictate. Accessibility lets the dictation key work and lets Nscribe type into \
            other apps; you allow it in System Settings, under Privacy & Security, then \
            Accessibility. Screen & System Audio Recording is needed only to record the \
            other side of a call, and only if you turn that on.

            To see which are allowed, open Nscribe's Settings and choose Dictation. The \
            Status list at the top marks each one, and an "Open System Settings" button \
            sits beside any that needs you.
            """,
        topic: .privacy,
        action: .nscribeSettings(.dictation)
    )

    static let privacy = HelpArticle(
        id: "privacy",
        title: "What leaves your Mac",
        body: """
            Your voice, your audio and your text are never sent to a server. Transcription \
            runs on Apple's speech recognizer, rewriting and summaries on Apple's \
            on-device model, and speaker separation on models stored on this Mac. Once \
            Apple's speech model is on your Mac, you can use Nscribe offline: dictation, \
            rewriting and meetings work with no internet connection.

            Nscribe reaches the network for three things only, and sends none of your \
            data. Apple downloads its speech model the first time you dictate. Once a day, \
            and when you choose "Check for Updates…", Nscribe reads a small file from the \
            latest release on GitHub; the request names only the app and its version. The \
            daily check stops if you turn off "Update automatically" in Settings, under \
            About. The speaker models download from HuggingFace only when you click \
            "Install Models" in Settings, under Meetings.
            """,
        topic: .privacy
    )

    static let storedData = HelpArticle(
        id: "stored-data",
        title: "What Nscribe keeps on your Mac",
        body: """
            Nscribe saves everything you dictate in plain text on this Mac, as recent \
            dictations, so that a dictation which landed in the wrong window can be \
            recovered. It keeps the last 100. To save no dictations at all, open Nscribe's \
            Settings, choose Dictation, and turn off "Keep recent dictations". "Clear \
            All…" in the Recent Dictations window deletes the ones already kept.

            Meetings keep their transcript, summary and recording. To keep no recordings, \
            turn off "Keep the recording after a meeting ends" in Settings, under \
            Meetings. A deleted meeting is erased for good after 30 days in Recently \
            Deleted.
            """,
        topic: .privacy,
        action: .nscribeSettings(.dictation)
    )

    // MARK: - Troubleshooting

    static let globeKeyEmoji = HelpArticle(
        id: "globe-key-emoji",
        title: "The Globe key opens the emoji picker",
        body: """
            macOS uses the Globe key (🌐) too. If pressing it opens the emoji picker with \
            its emoji and smileys, or switches your keyboard or input source, open System \
            Settings, choose Keyboard, and set "Press 🌐 key to" to Do Nothing. That \
            setting belongs to macOS, not to Nscribe. The "Open Keyboard Settings" link in \
            Nscribe's Dictation settings opens that page of System Settings.

            The emoji picker is still on Control-Command-Space (⌃⌘Space), Apple's own \
            default.
            """,
        topic: .troubleshooting,
        action: .keyboardSettings
    )

    static let keyDoesNothing = HelpArticle(
        id: "key-does-nothing",
        title: "The dictation key does nothing",
        body: """
            When you press the Globe key or your shortcut and nothing happens, Nscribe \
            most likely lacks Accessibility access, which it needs to notice the key. \
            Without it, the first line of Nscribe's menu says "The dictation key is not \
            working." and the N in the menu bar becomes a warning triangle.

            Choose "Allow Accessibility Access…" from Nscribe's menu and turn Nscribe on \
            in the list macOS shows. The key starts working within a few seconds, with no \
            restart. If Nscribe is already on in that list, choose "Try Again" from the \
            menu instead.

            If you build Nscribe yourself, the key stops working after each rebuild, \
            because each build is a new app to macOS. Remove Nscribe from the \
            Accessibility list and add it again.
            """,
        topic: .troubleshooting
    )

    static let nothingHeard = HelpArticle(
        id: "nothing-heard",
        title: "The panel says nothing was heard",
        body: """
            "Nothing was heard." means the dictation ended with no words. The panel names \
            the microphone it listened to, so check that it is the one you are speaking \
            into. To choose another, click the N in the menu bar and open the Microphone \
            menu. Nscribe starts listening when the start sound plays, so begin talking \
            after it.

            If the microphone is right, check that macOS lets Nscribe use it. Open \
            Nscribe's Settings and choose Dictation. The Status list at the top shows \
            whether Microphone and Speech recognition are allowed, and "Open System \
            Settings" beside either one goes to the switch for it.
            """,
        topic: .troubleshooting,
        action: .nscribeSettings(.dictation)
    )

    static let copiedNotTyped = HelpArticle(
        id: "copied-not-typed",
        title: "The words were copied instead of typed",
        body: """
            When Nscribe finds no text field to type into, it puts your words on the \
            clipboard, and the panel says "Copied. Press ⌘V to paste." Click where the \
            words belong and press Command-V (⌘V).

            If every dictation is copied, even into a document, open Nscribe's Settings, \
            choose Dictation, and set "After transcribing" to "Type into the focused \
            field, otherwise copy".

            "Pasted, but the app did not confirm it." means Nscribe typed the words but \
            the app never reported them arriving. Some apps report late or not at all, \
            among them Slack and other apps built on Chrome's engine. If the words are \
            missing, they are on the clipboard.
            """,
        topic: .troubleshooting
    )

    static let appleIntelligence = HelpArticle(
        id: "apple-intelligence",
        title: "Apple Intelligence is off or still downloading",
        body: """
            Rewriting dictations, meeting titles and summaries, and answers in Help all \
            run on Apple's on-device model, so they need Apple Intelligence. Dictation and \
            meeting transcripts work without it.

            Open Nscribe's Settings and choose Dictation. The Status list at the top says \
            whether Apple Intelligence is ready. If it is turned off, open System \
            Settings, choose Apple Intelligence & Siri, and turn it on. If it is still \
            downloading its model, try again once the download has finished. On a Mac that \
            does not support Apple Intelligence, the Status list says so.

            Until it is ready, Nscribe types your dictations as they were heard, and a \
            meeting gets no summary.
            """,
        topic: .troubleshooting,
        action: .nscribeSettings(.dictation)
    )

    static let rewriteFailed = HelpArticle(
        id: "rewrite-failed",
        title: "The panel says the rewrite failed",
        body: """
            "Delivered as heard. The rewrite failed." means Nscribe typed your words as \
            the speech recognizer heard them, because the rewrite did not finish. A failed \
            rewrite never costs you the words.

            The rewrite fails when Apple Intelligence is off or still downloading, when \
            Apple's model takes longer than 20 seconds, or when the model declines to \
            process the text. If "When something goes wrong" is on in the Feedback \
            settings, a notification gives the reason. To stop rewriting altogether, click \
            the N in the menu bar, open the Rewrite menu, and choose Off.
            """,
        topic: .troubleshooting
    )

    static let callAudioSilent = HelpArticle(
        id: "call-audio-silent",
        title: "The other side of the call is missing",
        body: """
            Nscribe records the other person on a call only when "Record system audio, for \
            the other side of a call" is on in Settings, under Meetings, and macOS allows \
            it.

            If the meeting says "No system audio has been heard in the first minute", open \
            System Settings, choose Privacy & Security, then Screen & System Audio \
            Recording, and turn Nscribe on. macOS gives Nscribe no way to check this \
            permission, so the meeting can only notice the silence. If the meeting page \
            says "Microphone only", system audio could not start for that meeting, and \
            only your side is transcribed. The call must also play through this Mac.
            """,
        topic: .troubleshooting,
        action: .screenRecordingSettings
    )

    static let noSpeakerNames = HelpArticle(
        id: "no-speaker-names",
        title: "Meetings have no speaker names",
        body: """
            Meetings show who said what only when the speaker models are installed. They \
            come separately from the app. Open Nscribe's Settings, choose Meetings, and \
            click "Install Models" under Speaker Separation. They download once, about 21 \
            MB from HuggingFace, and then run on this Mac with no network.

            Speakers are separated when a meeting ends, because telling voices apart needs \
            the whole recording. A meeting recorded before the models were installed \
            keeps a single speaker, and installing them later does not change it. To give \
            its lines to other people by hand, click the speaker's name on a line and \
            choose "A New Speaker".

            "Check for Updates" in the same place compares your copy with the published \
            models, and "Re-download Models" replaces it.
            """,
        topic: .troubleshooting,
        action: .nscribeSettings(.meetings)
    )

    static let microphoneBusy = HelpArticle(
        id: "microphone-busy",
        title: "Dictation won't start during a meeting",
        body: """
            A meeting and a dictation cannot use the microphone at once. While a meeting \
            records, the dictation key plays the error sound and the panel says "A meeting \
            is using the microphone."

            To dictate during a meeting, pause it first: click Pause in the meeting pill, \
            or choose "Pause Meeting" from Nscribe's menu. Dictate, then click Resume. In \
            the same way, a meeting cannot start until a dictation has finished.
            """,
        topic: .troubleshooting
    )

    static let diagnostics = HelpArticle(
        id: "diagnostics",
        title: "Find out what went wrong",
        body: """
            Open Nscribe's Settings, choose About, and open "What Nscribe has been doing". \
            This is Nscribe's log of what it has done since it was last started, with \
            problems in orange. Click "Refresh" to bring it up to date.

            To send the log to Nscribe's developer, click "Copy" and paste it into your \
            report. The "Nscribe on GitHub" link on the same tab opens the project's page. \
            Anything you wrote or said is redacted by macOS before it reaches this list.
            """,
        topic: .troubleshooting,
        action: .nscribeSettings(.about)
    )

    static let resetSettings = HelpArticle(
        id: "reset-settings",
        title: "Reset all settings",
        body: """
            Open Nscribe's Settings, choose About, click "Reset All Settings…", and then \
            click Reset. Every setting goes back to its default, and the dictation key \
            becomes the Globe key again.

            This also clears your word replacements, vocabulary, app profiles and recorded \
            key combinations. Your prompts are kept, and so are your recent dictations and \
            meetings. A reset cannot be undone.
            """,
        topic: .troubleshooting,
        action: .nscribeSettings(.about)
    )
}
