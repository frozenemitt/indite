import Foundation
import os
import Observation
import SwiftData

#if os(macOS)
import AppKit
#endif

/// Owns one recording from hotkey press to delivered text.
///
/// The menu bar button and the global hotkey both run this, so feedback sounds,
/// notifications, the AI fallback and the output decision stay in one place.
@MainActor
@Observable
final class RecordingCoordinator {

    // MARK: - Dependencies

    private let engine: TranscriptionEngine
    private let aiProcessor: AIProcessor
    private let settings: AppSettings

    // MARK: - State

    /// Where the last result went, kept with the dictation in its history.
    private(set) var lastDestination: String?

    /// Set by the app once the store is open, so finished dictations can be kept.
    var modelContext: ModelContext?

    #if os(macOS)
    private let overlay: DictationOverlayController

    /// Polls the engine while recording so the overlay tracks the live text.
    ///
    /// A timer rather than observation: the transcriber revises its volatile text many
    /// times a second, and redrawing a window on every revision is wasteful. It runs at
    /// twenty a second for the level band's sake; the text is only handed over when it
    /// has actually changed, so the cost of the faster tick is one number.
    private var overlayTicker: Task<Void, Never>?

    /// Mutes the Mac once the start sound has been heard, when the setting asks for it.
    /// Cancelled by `unmute()`, so a dictation that ends sooner mutes nothing.
    @ObservationIgnored private var muteTask: Task<Void, Never>?

    /// Whether this dictation has muted the Mac yet, so a lock sound knows whether it
    /// can still be heard.
    @ObservationIgnored private var hasMuted = false

    /// Watches the microphone while a dictation records. See `watchMicrophone()`.
    @ObservationIgnored private var microphoneWatch: Task<Void, Never>?

    /// The microphone this dictation records from, by name, for its warnings.
    @ObservationIgnored private var microphoneName = ""

    /// What the microphone itself says stops it hearing, kept current by its listener.
    @ObservationIgnored private var microphoneProblem: MicrophoneProblem?

    /// When the microphone last said its problem had gone, such as being unmuted.
    @ObservationIgnored private var microphoneFixedAt: ContinuousClock.Instant?

    /// Why the microphone is not heard, as the dictation shows it now, or nil while it is.
    @ObservationIgnored private var microphoneTrouble: MicrophoneTrouble?

    /// The last trouble this dictation showed, kept after it clears, so that a dictation
    /// whose microphone never sent sound can say why at its end.
    @ObservationIgnored private var lastMicrophoneTrouble: MicrophoneTrouble?

    /// The alarm for a warning, waiting for the start sound to finish.
    @ObservationIgnored private var alarmTask: Task<Void, Never>?

    /// Whether this dictation posted its microphone warning as a notification, with
    /// the panel off, so the warning's end can withdraw it.
    @ObservationIgnored private var postedMicrophoneWarning = false

    /// When this dictation's start sound will have played out.
    @ObservationIgnored private var startSoundEnds: ContinuousClock.Instant?
    #endif

    /// The lock sound, waiting for the start sound to finish. Cancelled when the
    /// dictation ends.
    @ObservationIgnored private var lockSoundTask: Task<Void, Never>?

    /// Called when the key asked for a recording that does not exist: a start refused
    /// because the engine is busy or a dictation is still being delivered, or a lock
    /// with no recording to lock. The hotkey then forgets the lock or the waiting tap.
    var onNoRecording: (() -> Void)?

    #if os(macOS)
    /// Whoever was frontmost when recording began — the app the text belongs to.
    private var targetApp: NSRunningApplication?

    /// Overrides for the target app, resolved once at the start of the recording.
    ///
    /// Pinned at the start rather than read at delivery: the user may have switched
    /// apps while talking, and the settings that applied when they began are the ones
    /// they were thinking of.
    private var activeProfile: AppProfile?
    #endif

    /// Whether this dictation has shown itself with the start sound and the panel.
    private var isAnnounced = false

    /// Whether to show it as soon as the microphone is live. A hold-to-talk press
    /// starts without, so that a tap shows nothing; `confirm()` sets it once the press
    /// turns out to be a dictation.
    private var announcesWhenLive = true

    /// Whether a double tap has locked this dictation on, so it goes on after the key
    /// comes up.
    private var isLocked = false

    /// Stops a recording that has run past `settings.maxRecordingSeconds`.
    private var maxDurationTask: Task<Void, Never>?

    /// The start still coming up, if there is one.
    ///
    /// Bringing the engine up takes a moment, and so can waiting for the previous
    /// dictation to hand it back; a push-to-talk tap can be shorter than either. The
    /// release waits here instead of being dropped, which is what used to leave the
    /// microphone live with nobody holding the key.
    private var startTask: Task<Void, Never>?

    /// The engine teardown still finishing, if there is one.
    ///
    /// Only the engine's part, not the AI pass that follows it: the next dictation
    /// should wait about a tenth of a second for the microphone, not several seconds
    /// for a model to answer.
    private var stopTask: Task<String, Never>?

    /// True from the moment the engine lets go until the text has landed.
    ///
    /// The AI pass can take seconds, and the text belongs to the app that was
    /// frontmost when it was spoken. A second dictation started in the meantime would
    /// have the first one's words activated into the first one's app, pulling focus
    /// away from the sentence being spoken right now.
    private(set) var isDelivering = false

    /// True only while the dictation's own AI rewrite runs. What the menu bar's brain
    /// icon follows: `isDelivering` also covers the engine drain and the paste, which
    /// run with AI off too.
    private(set) var isRewriting = false

    /// True only while *this* coordinator's dictation is running.
    ///
    /// Not `engine.isRecording`: the engine is shared with meeting mode, and a meeting
    /// would otherwise look like a dictation to every guard here.
    var isRecording: Bool { engine.owner == .dictation && engine.isRecording }

    /// True from the moment a dictation starts coming up until it stops recording.
    ///
    /// What Escape should cancel. `isRecording` is false for the 70–470 ms the engine
    /// takes to start, and an Escape pressed then went to the app instead.
    var isCancellable: Bool {
        engine.owner == .dictation && (engine.phase == .starting || engine.phase == .recording)
    }

    /// True from the moment a dictation starts recording until it has stopped and its
    /// words, if any, are in the history.
    ///
    /// A start still coming up holds no words, because the user waits for the start
    /// sound before speaking, so a quit does not wait on it. A start that is waiting
    /// on the previous dictation's stop is still covered by `stopTask`.
    ///
    /// The history is written only once the engine has let go, so a quit anywhere in
    /// this span would otherwise lose every word spoken. With the history off the
    /// quit still waits, so the engine stops and finishes the dictation's audio log.
    var hasUnsavedDictation: Bool {
        stopTask != nil || isRecording
    }

    /// The most recent app other than Indite to come to the front.
    ///
    /// A dictation started from the menu bar can find Indite itself frontmost, and
    /// the text belongs to the app the user was in before they clicked.
    #if os(macOS)
    @ObservationIgnored private var lastExternalApp: NSRunningApplication?
    @ObservationIgnored private var activationObserver: (any NSObjectProtocol)?

    /// The profile of the app the next dictation would go to, if it has one.
    ///
    /// Observed, for the menu, which says when an app's own rule overrides the choice
    /// it shows. Assigned only when it changes, which is when the user moves between
    /// an app with a profile and one without.
    private(set) var frontProfile: AppProfile?
    #endif
    @ObservationIgnored private var interruptionObserver: (any NSObjectProtocol)?

    /// What the target field held when the dictation began, for the AI pass.
    ///
    /// Read at the start rather than at delivery: the request warmed while the user
    /// speaks has to open with the same text as the request sent at release, and the
    /// field has not changed in between, since nothing is pasted until the end.
    @ObservationIgnored private var surroundingText: String?

    /// Warms the AI session on the words confirmed so far, while recording.
    @ObservationIgnored private var prefixWarmer: Task<Void, Never>?

    /// The history entry for the dictation being delivered, written by the stop task.
    ///
    /// Kept inside the stop rather than after it, so a quit that waits on the stop
    /// finds the words already in the history.
    @ObservationIgnored private var deliveringEntry: Dictation?

    /// When the microphone opened for the dictation under way. The history keeps how
    /// long it listened, for the speaking speed. The clock stops while the Mac sleeps,
    /// since a Mac asleep in the middle of a dictation is not listening.
    @ObservationIgnored private var microphoneOpenedAt: SuspendingClock.Instant?

    /// Where the dictation under way keeps its audio, while Recent Dictations keeps
    /// dictations. Closed once the engine has stopped, and named on the entry.
    @ObservationIgnored private var recording: DictationAudioWriter?

    /// Longest the AI pass may take before the raw transcript is delivered instead.
    ///
    /// Until the text lands, every press is refused as "still delivering", so a model
    /// that never answers would otherwise hold the hotkey until relaunch.
    private static let aiDeadline: Double = 20

    // MARK: - Initialization

    init(engine: TranscriptionEngine, aiProcessor: AIProcessor, settings: AppSettings) {
        self.engine = engine
        self.aiProcessor = aiProcessor
        self.settings = settings
        CorrectionWatcher.shared.settings = settings
        #if os(macOS)
        self.overlay = DictationOverlayController(settings: settings)
        // Checked as the observer below checks it, so Indite is never its own target.
        // With Indite in front at launch, no app is known until another comes
        // forward, and text delivered before then goes to the clipboard.
        if let app = NSWorkspace.shared.frontmostApplication,
           app.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            lastExternalApp = app
            frontProfile = settings.profile(forBundleIdentifier: app.bundleIdentifier)
        }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
            MainActor.assumeIsolated {
                guard let self else { return }
                self.lastExternalApp = app
                let profile = self.settings.profile(forBundleIdentifier: app.bundleIdentifier)
                if self.frontProfile != profile { self.frontProfile = profile }
            }
        }
        #endif

        // A microphone that changes mid-dictation ends the capture. Deliver what was
        // heard up to that point rather than leave the key recording silence.
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: TranscriptionEngine.captureInterruptedNotification,
            object: engine,
            queue: .main
        ) { [weak self] note in
            guard (note.userInfo?["owner"] as? TranscriptionEngine.SessionOwner) == .dictation else { return }
            MainActor.assumeIsolated {
                guard let self else { return }
                Task { await self.stopAndProcess() }
            }
        }
    }

    #if os(macOS)
    /// Put the overlay back at the bottom of the screen, for the settings screen.
    func resetOverlayPosition() {
        overlay.resetPosition()
    }
    #endif

    // MARK: - Resolved Settings

    /// The prompt this dictation runs, or nil when its words go out as they were heard.
    ///
    /// An app's profile decides first, and it can turn rewriting off for that app as
    /// well as choose a prompt. Otherwise the menu's Rewrite choice decides. Off is
    /// stored as the prompt that does nothing, so a profile can hold it.
    private var rewritePromptId: UUID? {
        var promptId = settings.aiEnabled
            ? settings.selectedPromptId ?? PromptConfiguration.defaultPromptId
            : PromptConfiguration.rawPromptId
        #if os(macOS)
        if let override = activeProfile?.promptId { promptId = override }
        #endif
        return promptId == PromptConfiguration.rawPromptId ? nil : promptId
    }

    #if os(macOS)
    /// Set while the welcome window's practice box is showing. A dictation made with
    /// Indite in front lands there; otherwise Indite is never its own target, and the
    /// practice words would be typed into the app behind the welcome window.
    var practiceReceiver: ((String) -> Void)?

    private var practiceIsInFront: Bool {
        practiceReceiver != nil
            && NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier
    }

    /// The app in front, or the one before it when that is Indite itself: a click on
    /// Indite's menu brings Indite forward, and the text is never meant for it.
    /// Dictation History's Insert button uses it too, because Indite is frontmost
    /// whenever that button is clicked.
    var appInFront: NSRunningApplication? {
        let frontmost = NSWorkspace.shared.frontmostApplication
        return frontmost?.processIdentifier == ProcessInfo.processInfo.processIdentifier
            ? lastExternalApp
            : frontmost
    }

    /// Whether text for `app` is typed into it rather than only copied, by its
    /// profile's choice or the general one, as `deliver` decides it.
    private func typesText(into app: NSRunningApplication?) -> Bool {
        let profile = settings.profile(forBundleIdentifier: app?.bundleIdentifier)
        return (profile?.outputModeRaw.flatMap(OutputMode.init(rawValue:)) ?? settings.outputMode) == .smartInsert
    }
    #endif

    // MARK: - Recording Control

    func toggle() async {
        // A second press during the start is the user asking to stop, so let the
        // session finish coming up and then end it, rather than reading the
        // half-built state as "not recording" and opening a second microphone.
        if let startTask { await startTask.value }

        if isRecording {
            await stopAndProcess()
        } else {
            await start()
        }
    }

    /// - Parameter announced: Play the start sound and show the panel as soon as the
    ///   microphone is live. False for a hold-to-talk press, which waits for `confirm()`.
    func start(announced: Bool = true) async {
        // One start at a time. A press, release and press queued behind a busy main
        // thread used to run two starts together, and the second tore down the first.
        //
        // Claimed before anything is awaited, the wait for the previous stop included.
        // A release that landed during that wait used to find no start in flight and
        // was dropped. The microphone then opened with nobody holding the key.
        guard startTask == nil else { return }
        // A start that will be refused, because a dictation is already recording, must
        // leave that dictation's state alone. Resetting it here let the running
        // dictation announce itself a second time and schedule a second mute.
        if !isRecording {
            isAnnounced = false
            isLocked = false
            announcesWhenLive = announced
        }
        let task = Task { await self.begin() }
        startTask = task
        await task.value
        startTask = nil
    }

    private func begin() async {
        // Let the previous dictation hand the engine back before claiming it. Without
        // this the new session cleared the old one's transcript out from under it and
        // both sets of words were lost.
        if let stopTask { _ = await stopTask.value }

        guard !isDelivering else {
            Log.dictation.notice("Still delivering the last dictation")
            AudioFeedbackService.shared.playIfEnabled(.error, settings: settings)
            onNoRecording?()
            return
        }

        // Refuse to start over anyone's session, including a meeting's, and including
        // one that is still coming up. Said out loud: a silent refusal has the user
        // talking into nothing.
        guard !engine.isBusy else {
            Log.dictation.notice("Engine busy with \(self.engine.owner?.rawValue ?? "another session", privacy: .public), not starting")
            AudioFeedbackService.shared.playIfEnabled(.error, settings: settings)
            report(.problem(engine.owner == .meeting
                            ? "A meeting is using the microphone."
                            : "Indite is already recording."))
            onNoRecording?()
            return
        }

        #if os(macOS)
        // Captured before we touch anything, so a menu bar click that steals focus
        // does not redirect the text to Indite itself. This app decides the prompt
        // and the text around the cursor, both readied while the user talks; the text
        // itself goes to whichever app is in front when it is ready.
        targetApp = practiceIsInFront ? nil : appInFront
        activeProfile = settings.profile(forBundleIdentifier: targetApp?.bundleIdentifier)

        if let activeProfile {
            Log.dictation.notice("Using profile for \(activeProfile.appName, privacy: .public)")
        }
        #endif

        #if os(macOS)
        let microphone = AudioDeviceCatalog.microphoneForRecording(settings.microphoneOrder)
        let inputDeviceUID = microphone.uid
        #else
        let inputDeviceUID = AudioInputDevice.systemDefaultUID
        #endif

        // A recording is kept only with its entry, so only while entries are kept.
        let recording = settings.keepDictationHistory ? DictationAudioWriter() : nil
        do {
            try await engine.startRecording(
                owner: .dictation,
                vocabulary: settings.vocabularyHints,
                inputDeviceUID: inputDeviceUID,
                publishesSpectrum: settings.showDictationOverlay,
                keepingAudioIn: recording
            )
            self.recording = recording
        } catch {
            recording?.discard()
            AudioFeedbackService.shared.playIfEnabled(.error, settings: settings)
            NotificationService.shared.showErrorIfEnabled(error.localizedDescription, settings: settings)
            report(.problem(error.localizedDescription))
            Log.dictation.error("Failed to start: \(error, privacy: .public)")
            return
        }

        microphoneOpenedAt = SuspendingClock.now
        #if os(macOS)
        watchMicrophone(chosen: microphone.microphone)
        #endif
        if announcesWhenLive { announce() }
        startMaxDurationWatchdog()

        // Load the model while the user is still speaking. It has to be in memory
        // before it can answer, and that load used to begin only once they had
        // finished — seconds of waiting bolted onto seconds of talking.
        let usesAI = rewritePromptId != nil
        if usesAI {
            aiProcessor.prewarm(promptId: rewritePromptId)
        }

        Log.dictation.notice("Recording started")

        // Accessibility work on the target app, after the sound and the panel and
        // outside the start the release waits for. Each call waits on the target app,
        // and reading the field of an Electron app held the start sound back by up to
        // 0.37 s.
        surroundingText = nil
        #if os(macOS)
        let target = targetApp
        let wantsContext = usesAI && settings.useSurroundingContext
        Task { [weak self] in
            // Chromium-based apps need to be told to build an accessibility tree, and
            // it takes them a moment. Asking now means it is ready by the time we
            // deliver.
            TextInsertionService.prepareForInsertion(into: target)
            guard let self, self.isRecording else { return }
            if wantsContext {
                self.surroundingText = TextInsertionService.focusedFieldContext(in: target)
            }
            // Only now, since the request opens with the text around the cursor and a
            // warmed prefix without it would match nothing.
            if usesAI { self.startPrefixWarmer() }

            // Names on screen join the vocabulary for this dictation. Read off the main
            // thread, within 400 ms. Words Indite itself typed in the last day are left
            // out: they are its own earlier guesses, and a mishearing on screen ("Dristy
            // Quest") would otherwise be taken for a name.
            if !self.settings.vocabularyHints.isEmpty, let pid = target?.processIdentifier {
                let reading = await Task.detached(priority: .utility) { ScreenVocabulary.read(processIdentifier: pid) }.value
                let typed = self.recentlyTyped()
                let names = reading.terms.filter { !typed.contains(Vocabulary.key($0)) }
                self.engine.useScreenTerms(names)
                Log.dictation.notice("Screen: \(names.count, privacy: .public) names kept of \(reading.terms.count, privacy: .public), read in \(reading.milliseconds, privacy: .public) ms")
            }
        }
        #else
        if usesAI {
            startPrefixWarmer()
        }
        #endif
    }

    /// Show a hold-to-talk recording: the key has been held past a tap, or pressed a
    /// second time for a double tap. The microphone has been live since the press, so
    /// nothing said before this is lost.
    func confirm() {
        announcesWhenLive = true
        if isRecording { announce() }
    }

    /// Say that a double tap has locked the recording on: the lock sound, and a lock
    /// in the panel until the recording ends.
    ///
    /// The second tap can come up before the microphone is live, since starting it
    /// takes up to 470 ms. The start sound has not played yet then, so the lock waits
    /// for it rather than sounding first.
    func lock() {
        // A lock queued behind a stop, or behind a refused start, has nothing to lock.
        guard startTask != nil || isRecording, !isDelivering else {
            onNoRecording?()
            return
        }
        isLocked = true
        if isAnnounced { announceLock(after: 0) }
    }

    /// The start sound and the panel, once per dictation.
    private func announce() {
        guard !isAnnounced else { return }
        isAnnounced = true

        // Sounded only once capture is live, so the user does not talk over the gap:
        // `startRecording` returns after the audio engine has started, and every
        // buffer from that moment on is kept.
        let startSound = AudioFeedbackService.shared.playIfEnabled(.recordingStarted, settings: settings)
        Log.dictation.notice("Start sound played")

        #if os(macOS)
        startSoundEnds = .now + .seconds(startSound)
        if settings.showDictationOverlay {
            overlay.show()
            startOverlayTicker()
        }
        #endif

        if isLocked {
            // Locked before the microphone was live, which a slow start allows. The lock
            // sound follows the start sound instead of starting with it: both sit near
            // 700 Hz, and played together the lock is not heard.
            announceLock(after: startSound)
        } else {
            #if os(macOS)
            // A double tap locks at most one tap after this press, so the mute also waits
            // that long. Muting sooner played the lock sound into a silent Mac whenever
            // the start sound was shorter than the tap, or set to None.
            if settings.muteWhileDictating { mute(after: max(startSound, Self.lockWindow)) }
            #endif
        }
    }

    /// The lock sound, and the lock in the panel.
    ///
    /// - Parameter delay: How long to wait before the sound, for a start sound still
    ///   playing. The lock shows in the panel at once.
    private func announceLock(after delay: TimeInterval) {
        #if os(macOS)
        if settings.showDictationOverlay { overlay.showLocked() }
        #endif
        lockSoundTask?.cancel()
        lockSoundTask = Task {
            if delay > 0 {
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled else { return }
            }
            let lockSound = AudioFeedbackService.shared.playIfEnabled(.recordingLocked, settings: settings)
            #if os(macOS)
            // The Mac goes quiet only once the lock sound has been heard. A mute that has
            // already landed stays: the lock still shows in the panel.
            if settings.muteWhileDictating, !hasMuted { mute(after: lockSound) }
            #endif
        }
    }

    /// How long after a press its double tap can still lock the recording: the 300 ms a
    /// tap may last, and a margin for the event to reach the main actor.
    private static let lockWindow: TimeInterval = 0.5

    /// Stop, transcribe, optionally run the AI pass, then deliver the text.
    func stopAndProcess() async {
        // A release that lands while the engine is still coming up waits for it,
        // rather than being dropped and leaving the microphone running.
        if let startTask { await startTask.value }

        // Claimed in the same step as the check. Two releases waiting on one start
        // both used to pass `isRecording`, and the second stopped a session the first
        // was already delivering, then cleared the flag while the first still was.
        guard isRecording, !isDelivering else { return }
        isDelivering = true
        defer { isDelivering = false }

        // Measured at the stop, not once the engine has finished with the audio.
        let spokenDuration = microphoneOpenedAt.map { (SuspendingClock.now - $0) / .seconds(1) }

        maxDurationTask?.cancel()
        maxDurationTask = nil
        prefixWarmer?.cancel()
        prefixWarmer = nil

        lockSoundTask?.cancel()
        lockSoundTask = nil
        #if os(macOS)
        stopWatchingMicrophone()
        unmute()
        #endif
        AudioFeedbackService.shared.playIfEnabled(.recordingStopped, settings: settings)

        #if os(macOS)
        stopOverlayTicker()
        if settings.showDictationOverlay, rewritePromptId != nil {
            overlay.showProcessing()
        } else {
            overlay.hide()
        }
        #endif

        // Pause-mark cleanup and word replacements run before the AI pass, so a
        // corrected term reaches the model already spelled the way the user wants
        // rather than being "corrected" back.
        //
        // Done inside the stop task, and an empty result gives up the delivering flag
        // there too. A press waiting on this task then finds the way clear, instead of
        // being refused as "still delivering" by a dictation with nothing to deliver.
        let replacements = settings.wordReplacements
        let recording = self.recording
        self.recording = nil
        let stop = Task { [engine] () -> String in
            let raw = await engine.stopRecording(owner: .dictation)
            // Closed once the engine has handed its last buffer over.
            let recordingFileName = recording?.finish()
            let processed = TextProcessor.process(raw, replacements: replacements)
            if processed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                DictationAudioStore.delete(fileNamed: recordingFileName)
                self.isDelivering = false
            } else {
                // Kept before anything else can fail or the app can quit: from here on
                // the words survive a hung AI pass, a paste into the wrong window, or a
                // quit mid-delivery, which waits on this task. The entry is brought up
                // to date once the text has landed.
                self.deliveringEntry = self.recordHistory(processed, spokenDuration: spokenDuration,
                                                          recordingFileName: recordingFileName)
            }
            return processed
        }
        stopTask = stop
        let heard = await stop.value
        stopTask = nil

        guard !heard.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            // A session loaded for this dictation's prompt would otherwise be picked up
            // by the next one, with the instructions it held when it was loaded.
            aiProcessor.discardPrewarm()

            // A recognizer that failed and a room that was quiet used to look exactly
            // the same from outside: both ended in silence with no text. Say which.
            if let engineError = engine.error {
                AudioFeedbackService.shared.playIfEnabled(.error, settings: settings)
                NotificationService.shared.showErrorIfEnabled(
                    engineError.localizedDescription,
                    settings: settings
                )
                report(.problem(engineError.localizedDescription))
                Log.dictation.error("Recognition failed: \(engineError, privacy: .public)")
            } else if !engine.receivedAudio, (spokenDuration ?? 0) < 0.5 {
                // Let go before the microphone's first buffer arrived, so nothing was
                // recorded and nothing failed. On 2026-11-08 two recordings ended 17
                // and 56 ms after they started, and each played the error sound and
                // blamed the microphone for what was an accidental tap.
                #if os(macOS)
                overlay.hide()
                #endif
                Log.dictation.notice("The recording ended before any audio arrived, so there is nothing to deliver")
            } else if let noSound = noSoundOutcome() {
                // The microphone never sent sound, and the panel said so while it ran.
                // "Nothing was heard" would blame a quiet room for a dead microphone.
                AudioFeedbackService.shared.playIfEnabled(.error, settings: settings)
                NotificationService.shared.showErrorIfEnabled(noSound.detail, title: noSound.headline, settings: settings)
                report(noSound)
                Log.dictation.notice("Empty transcript: the microphone sent no sound at all")
            } else {
                AudioFeedbackService.shared.playIfEnabled(.error, settings: settings)
                NotificationService.shared.showErrorIfEnabled(
                    "Nothing was heard. Check the input device in Settings.",
                    settings: settings
                )
                #if os(macOS)
                report(.nothingHeard(microphone: microphoneName))
                #endif
                Log.dictation.notice("Empty transcript, nothing to deliver")
            }
            return
        }

        // Written by the stop task, so a quit waiting on that task finds it kept.
        let entry = deliveringEntry
        deliveringEntry = nil

        // A recognizer that failed part-way, or a microphone that changed, still hands
        // back what it had. Delivered, and said: passing it off as complete hides that
        // the end is missing.
        var problem: String?
        if let engineError = engine.error {
            NotificationService.shared.showErrorIfEnabled(
                "\(engineError.localizedDescription) Everything heard before that was delivered.",
                settings: settings
            )
            problem = "Recognition stopped early."
            Log.dictation.error("Delivering a transcript cut short: \(engineError, privacy: .public)")
        }

        // A closing "press enter" is a command, not words. It comes off before the AI
        // pass, so the model never sees it and cannot reword it. It comes off only where
        // the words would be typed, since Indite presses keys nowhere else, and never in
        // the welcome window's practice box, which has nothing to send: there the words
        // are practice like any others.
        var spokenReturn: String?
        #if os(macOS)
        if settings.pressEnterSubmits, !practiceIsInFront, typesText(into: appInFront) {
            spokenReturn = TextProcessor.removingPressEnter(from: heard)
        }
        #endif
        let transcript = spokenReturn ?? heard
        let pressesReturn = spokenReturn != nil
        if pressesReturn {
            Log.dictation.notice("The dictation ended with press enter; Return follows the words")
        }

        #if os(macOS)
        // A dictation of only "press enter" sends what is already in the field, a
        // message read over before the command was said: Return, with nothing to type
        // and nothing to rewrite.
        if pressesReturn, transcript.isEmpty {
            aiProcessor.discardPrewarm()
            let pressed = await pressReturnAlone(problem: problem)
            finishHistory(entry, text: "", rawText: nil, promptName: nil)
            AudioFeedbackService.shared.playIfEnabled(pressed ? .processingComplete : .error, settings: settings)
            return
        }
        #endif

        // Snippets are expanded only after the AI pass, so the model never sees their
        // saved text. This is the dictation as heard, for when no rewrite is used.
        let snippets = settings.snippets
        let asHeard = Snippets.expand(transcript, snippets: snippets)

        guard let promptId = rewritePromptId else {
            // Loaded at the start if rewriting was on then; switched off mid-recording
            // leaves it unused.
            aiProcessor.discardPrewarm()
            await deliver(asHeard.text, problem: problem, pressesReturn: pressesReturn, keepsText: asHeard.expanded > 0)
            finishHistory(entry, text: asHeard.text, rawText: transcript, promptName: nil)
            AudioFeedbackService.shared.playIfEnabled(.processingComplete, settings: settings)
            NotificationService.shared.showTranscriptionCompleteIfEnabled(
                characterCount: asHeard.text.count,
                destination: lastDestination,
                settings: settings
            )
            return
        }

        // Normally read when the dictation began. Asked again now only if that found
        // nothing — a Chromium app can take a moment to expose its fields — and asked
        // of the app the dictation was aimed at, not whatever the user looks at now.
        var surroundingText = self.surroundingText
        #if os(macOS)
        if surroundingText == nil, settings.useSurroundingContext {
            surroundingText = TextInsertionService.focusedFieldContext(in: targetApp)
        }
        #endif
        // The rewrite is shown in the panel as it is written.
        var onPartial: (@MainActor (String) -> Void)?
        #if os(macOS)
        if settings.showDictationOverlay {
            let overlay = self.overlay
            onPartial = { @MainActor text in overlay.showRewrite(text) }
        }
        #endif

        AudioFeedbackService.shared.startProcessingLoop(settings: settings)

        // Held so the deadline can cancel it. `withDeadline` only stops waiting, and a
        // rewrite left running kept streaming into the next dictation's panel and held
        // the menu bar in its processing state until the model finished.
        isRewriting = true
        let aiPass = Task { [aiProcessor, onPartial, surroundingText] in
            try await aiProcessor.process(
                text: transcript,
                promptId: promptId,
                surroundingText: surroundingText,
                usesWarmSession: true,
                onPartial: onPartial
            )
        }
        // Whatever the pass did with it, the session warmed for this dictation is spent:
        // a prompt switched mid-dictation leaves it unused.
        defer { aiProcessor.discardPrewarm() }
        let finalText: String
        do {
            finalText = try await withDeadline(seconds: Self.aiDeadline) { try await aiPass.value }
            isRewriting = false
            AudioFeedbackService.shared.stopProcessingLoop()
        } catch {
            isRewriting = false
            aiPass.cancel()
            // A failed AI pass must not cost the user their words, and neither may a
            // model that never answers: past the deadline the raw transcript goes out.
            AudioFeedbackService.shared.stopProcessingLoop()
            let detail = error is DeadlineExceeded
                ? "The AI pass took longer than \(Int(Self.aiDeadline)) seconds."
                : error.localizedDescription
            Log.dictation.error("AI failed, delivering raw transcript: \(detail, privacy: .public)")

            await deliver(asHeard.text, problem: "Delivered as heard. The rewrite failed.",
                          pressesReturn: pressesReturn, keepsText: asHeard.expanded > 0)
            finishHistory(entry, text: asHeard.text, rawText: transcript, promptName: nil)
            AudioFeedbackService.shared.playIfEnabled(.processingComplete, settings: settings)
            NotificationService.shared.showAIProcessingFailedIfEnabled(
                characterCount: asHeard.text.count,
                errorDetail: detail,
                settings: settings
            )
            return
        }

        // Only the cues the transcript held are expanded, each no more times than it
        // held it, so whether a snippet is typed never depends on the rewrite. A cue
        // the model reworded can no longer be found, so the saved text it stands for
        // would be lost. That dictation goes out as heard instead, with its cues
        // expanded, and the panel says so: it has just shown the rewrite being written.
        let rewritten = Snippets.expand(finalText, cuesOf: transcript, snippets: snippets)
        if rewritten == nil {
            Log.dictation.notice("The rewrite reworded a snippet's cue, so the dictation goes out as heard")
            problem = [problem, "Delivered as heard. The rewrite changed a snippet's cue."]
                .compactMap { $0 }.joined(separator: " ")
        }
        let delivered = rewritten ?? asHeard
        await deliver(delivered.text, problem: problem, pressesReturn: pressesReturn, keepsText: delivered.expanded > 0)
        let promptName = rewritten != nil ? aiProcessor.promptConfiguration.prompt(withId: promptId)?.name : nil
        finishHistory(entry, text: delivered.text, rawText: transcript, promptName: promptName)
        AudioFeedbackService.shared.playIfEnabled(.processingComplete, settings: settings)
        NotificationService.shared.showTranscriptionCompleteIfEnabled(
            characterCount: delivered.text.count,
            destination: lastDestination,
            settings: settings
        )
    }

    /// Every phrase Indite typed in the last day, from the dictation history.
    ///
    /// Each dictation as it was before snippets were expanded. A snippet's saved text is
    /// typed as the user wrote it, so the names in it are theirs, not Indite's earlier
    /// guesses, and the screen may lend them to the vocabulary like any other names.
    private func recentlyTyped() -> Set<String> {
        guard let modelContext else { return [] }
        let cutoff = Date().addingTimeInterval(-24 * 60 * 60)
        var descriptor = FetchDescriptor<Dictation>(
            predicate: #Predicate { $0.createdAt > cutoff },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        descriptor.fetchLimit = 300
        let snippets = settings.snippets
        let texts = (try? modelContext.fetch(descriptor))?.map { Snippets.unexpand($0.text, snippets: snippets) } ?? []
        return Vocabulary.phrases(in: texts.joined(separator: " "))
    }

    /// Keep the dictation the moment its words exist, with its recording.
    private func recordHistory(_ transcript: String, spokenDuration: TimeInterval?,
                               recordingFileName: String?) -> Dictation? {
        guard let modelContext else {
            DictationAudioStore.delete(fileNamed: recordingFileName)
            return nil
        }
        return DictationHistory.record(
            text: transcript,
            rawText: nil,
            destination: nil,
            promptName: nil,
            spokenDuration: spokenDuration,
            recordingFileName: recordingFileName,
            settings: settings,
            in: modelContext
        )
    }

    /// Bring the kept entry up to date with what was actually delivered.
    ///
    /// The prompt is named only when its output is what landed. A raw transcript
    /// delivered after the AI pass failed used to carry the prompt's name, and the
    /// default prompt's output carried none.
    ///
    /// - Parameter rawText: The words heard: the transcript before the AI pass and
    ///   before snippets are expanded, without a closing "press enter". Kept only where
    ///   it differs from the text. The speaking speed counts these words, so a snippet's
    ///   saved text used to count as words spoken.
    private func finishHistory(_ entry: Dictation?, text: String, rawText: String?, promptName: String?) {
        guard let entry, let modelContext, !entry.isDeleted else { return }
        // A dictation of only "press enter" typed nothing, so there is nothing to keep,
        // and Type Again types the dictation before it rather than the command.
        guard !text.isEmpty else {
            DictationAudioStore.delete(fileNamed: entry.recordingFileName)
            modelContext.delete(entry)
            modelContext.saveOrLog()
            return
        }
        entry.text = text
        entry.rawText = rawText == text ? nil : rawText
        entry.destination = lastDestination
        entry.promptName = promptName
        modelContext.saveOrLog()
    }

    /// Throw away an in-flight recording without producing any text.
    ///
    /// - Parameter quietly: Skip the stop sound, for a recording the user never meant
    ///   to start, such as one begun by Globe pressed as part of Fn+Delete, or by a
    ///   tap too short to hold any words.
    func cancel(quietly: Bool = false) async {
        if let startTask { await startTask.value }
        // Not while a stop is delivering: its words are already on their way.
        guard isRecording, !isDelivering else { return }
        maxDurationTask?.cancel()
        maxDurationTask = nil

        lockSoundTask?.cancel()
        lockSoundTask = nil
        #if os(macOS)
        stopOverlayTicker()
        stopWatchingMicrophone()
        overlay.hide()
        unmute()
        #endif

        prefixWarmer?.cancel()
        prefixWarmer = nil
        engine.cancelRecording(owner: .dictation)
        recording?.discard()
        recording = nil
        aiProcessor.discardPrewarm()
        lastDestination = nil
        if !quietly {
            AudioFeedbackService.shared.playIfEnabled(.recordingStopped, settings: settings)
        }
        Log.dictation.notice("Recording cancelled\(quietly ? " — the press was not a dictation" : "", privacy: .public)")
    }

    /// Stop the dictation under way for a quit, and keep its words in the history
    /// when the history is on.
    ///
    /// Nothing is pasted: during a logout or restart the app in front is not one the
    /// words were meant for. A stop already in flight writes its own entry inside the
    /// stop task, so waiting on that task is enough.
    func saveDictationForQuit() async {
        if let stopTask {
            _ = await stopTask.value
            return
        }
        guard isRecording, !isDelivering else { return }
        isDelivering = true
        defer { isDelivering = false }

        maxDurationTask?.cancel()
        maxDurationTask = nil
        prefixWarmer?.cancel()
        prefixWarmer = nil
        lockSoundTask?.cancel()
        lockSoundTask = nil
        #if os(macOS)
        stopOverlayTicker()
        stopWatchingMicrophone()
        overlay.hide()
        unmute()
        #endif
        aiProcessor.discardPrewarm()

        let spokenDuration = microphoneOpenedAt.map { (SuspendingClock.now - $0) / .seconds(1) }
        let recording = self.recording
        self.recording = nil
        let raw = await engine.stopRecording(owner: .dictation)
        let recordingFileName = recording?.finish()
        if recordHistory(TextProcessor.process(raw, replacements: settings.wordReplacements), spokenDuration: spokenDuration,
                         recordingFileName: recordingFileName) != nil {
            Log.dictation.notice("Kept the dictation in the history on quit")
        } else {
            Log.dictation.notice("Stopped the dictation on quit; it had nothing to keep")
        }
    }

    // MARK: - Output

    #if os(macOS)
    /// Whether the app in front is the one the dictation was aimed at, so that Return
    /// for "press enter" may go to it. The welcome window's practice box never is.
    private var frontIsWhereAimed: Bool {
        !practiceIsInFront && appInFront?.processIdentifier == targetApp?.processIdentifier
    }

    /// Press Return for a dictation that was only "press enter", where Return after
    /// words would be pressed: in the app the dictation was aimed at, into a text field.
    /// The stop has already kept the command to apps Indite types into, and nothing
    /// has been awaited since. Returns whether Return was pressed.
    private func pressReturnAlone(problem: String?) async -> Bool {
        overlay.hide()
        let reason: String
        if !frontIsWhereAimed {
            reason = "Another app is in front."
        } else if await TextInsertionService.pressReturn(in: appInFront) {
            if let problem { report(.problem(problem)) }
            return true
        } else {
            reason = "No text field has focus."
        }
        Log.dictation.notice("The dictation was only press enter, and Return was not pressed: \(reason, privacy: .public)")
        report(.problem([problem, "Return was not pressed. \(reason)"].compactMap { $0 }.joined(separator: " ")))
        return false
    }
    #endif

    /// Send finished text wherever the user's output setting says it goes.
    ///
    /// - Parameters:
    ///   - problem: Something that went wrong on the way, for the panel to say once the
    ///     text has landed.
    ///   - pressesReturn: Press Return after the paste, whatever the settings say,
    ///     because the dictation ended with "press enter". Only in the app the
    ///     dictation was aimed at.
    ///   - keepsText: Paste the text's own characters unchanged, because it holds a
    ///     snippet's saved text.
    private func deliver(_ text: String, problem: String? = nil, pressesReturn: Bool = false, keepsText: Bool = false) async {
        #if os(macOS)
        // The last dictation's field is judged before this one's words can land in it.
        // Not when this dictation started: a stray tap of the key starts one that
        // delivers nothing, and that ended the watch for nothing.
        CorrectionWatcher.shared.stopWatching()

        // Dismissed before insertion: the panel is borderless and non-activating, but
        // leaving it up while text lands is visual noise at the wrong moment.
        overlay.hide()

        // Return for "press enter" goes only to the app the dictation was aimed at. The
        // words can be ready seconds after the key came up, and Return in whatever app
        // is in front by then could send something there that nobody has read, or press
        // a dialog's default button. The words still go to the app in front, as any
        // dictation's do, with no Return after them, and the panel says so.
        var problem = problem
        let sends = pressesReturn && frontIsWhereAimed
        if pressesReturn, !sends {
            problem = [problem, "Return was not pressed. Another app is in front."].compactMap { $0 }.joined(separator: " ")
            Log.dictation.notice("Another app is in front of the one the dictation began in, so Return is not pressed")
        }

        if practiceIsInFront, let practiceReceiver {
            practiceReceiver(text)
            lastDestination = "Indite"
            if let problem { report(.problem(problem)) }
            return
        }

        // The app in front now, not the one the dictation began in: switching to the
        // app the text is for while still talking is normal. Its profile decides how
        // the text arrives.
        let destination = appInFront
        let profile = settings.profile(forBundleIdentifier: destination?.bundleIdentifier)
        let outputMode = profile?.outputModeRaw.flatMap(OutputMode.init(rawValue:)) ?? settings.outputMode
        // A dictation that said "press enter" presses Return where it was aimed and
        // nowhere else; the setting decides for every other dictation.
        let autoSubmit = pressesReturn ? sends : (profile?.autoSubmit ?? settings.autoSubmitAfterInsert)

        switch outputMode {
        case .clipboardOnly:
            ClipboardService.copy(text)
            lastDestination = "Clipboard"
            // Copying is what was asked for here, so only a problem is worth the panel.
            if let problem { report(.problem(problem)) }

        case .smartInsert:
            let outcome = await TextInsertionService.deliver(
                text,
                targetApp: destination,
                restoreClipboard: settings.restoreClipboardAfterPaste,
                autoSubmit: autoSubmit,
                // The words asked for Return, not the Shift-Return the setting may choose.
                submitUsesShift: !pressesReturn && settings.useShiftReturnAfterInsert,
                keepsText: keepsText,
                names: settings.vocabularyHints
            )
            switch outcome {
            case .inserted(let appName):
                lastDestination = appName
                if let problem { report(.problem(problem)) }
                // Not after Return: the message has gone, and there is nothing left to correct.
                // Nor a dictation that held a snippet's saved text: the user wrote that
                // text, so a name changed in it is an edit, not a mishearing.
                if !keepsText, let insertion = TextInsertionService.lastInsertion {
                    CorrectionWatcher.shared.watch(insertion)
                }
            case .copiedToClipboard:
                lastDestination = "Clipboard"
                // The setting says type, and the words were copied. That is the one
                // ending the user cannot see for themselves.
                report(problem.map { .problem($0, copied: true) } ?? .copied(text))
            case .pastedUnconfirmed:
                lastDestination = "Clipboard"
                report(problem.map { .problem($0, copied: true) } ?? .unconfirmed)
            }
        }
        #else
        ClipboardService.copy(text)
        lastDestination = "Clipboard"
        #endif
    }

    // MARK: - Typing Again

    /// Type the newest dictation in the history where the cursor is now.
    func typeLastDictation() async {
        var descriptor = FetchDescriptor<Dictation>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        descriptor.fetchLimit = 1
        guard let last = (try? modelContext?.fetch(descriptor))?.first else {
            AudioFeedbackService.shared.playIfEnabled(.error, settings: settings)
            report(.problem(settings.keepDictationHistory
                            ? "There is no dictation to type again."
                            : "History is off, so there is no dictation to type again."))
            return
        }
        await typeAgain(last.text)
    }

    /// Type a dictation from the history into the app in front, where the cursor is.
    ///
    /// For words that landed in the wrong place. Typed as they were delivered the first
    /// time, with no rewrite and no Return pressed after them: the point is to put
    /// them somewhere, and sending them is the user's to do.
    func typeAgain(_ text: String) async {
        // A dictation under way owns the panel and the paste.
        guard !isCancellable, !isDelivering else {
            AudioFeedbackService.shared.playIfEnabled(.error, settings: settings)
            return
        }
        #if os(macOS)
        let outcome = await TextInsertionService.deliver(
            text,
            targetApp: appInFront,
            restoreClipboard: settings.restoreClipboardAfterPaste,
            autoSubmit: false,
            // A snippet's saved text goes in as it was written, as it did the first time.
            keepsText: Snippets.holdsSavedText(text, snippets: settings.snippets),
            names: settings.vocabularyHints
        )
        switch outcome {
        case .inserted:
            AudioFeedbackService.shared.playIfEnabled(.processingComplete, settings: settings)
        case .copiedToClipboard:
            report(.copied(text))
        case .pastedUnconfirmed:
            report(.unconfirmed)
        }
        #else
        ClipboardService.copy(text)
        #endif
    }

    // MARK: - Transcribing Again

    /// The dictation in Recent Dictations being transcribed again, if one is.
    private(set) var transcribingAgain: PersistentIdentifier?

    /// Whether a dictation can be transcribed again now: not while one is being
    /// dictated or delivered, and one at a time.
    var canTranscribeAgain: Bool {
        !isCancellable && !isDelivering && transcribingAgain == nil
    }

    /// Transcribe a kept dictation again from its recording, with the Words settings
    /// and the rewriting choice as they are now, and put the result in its entry. The
    /// entry keeps its time, destination and recording.
    ///
    /// The words go through the steps a live dictation's take, apart from those that
    /// deliver them: nothing is typed, and a closing "press enter" stays as words, since
    /// no Return follows. The words wait in Recent Dictations to be inserted or copied.
    /// The entry is left as it was when any step fails, a rewrite included, since its
    /// words may be a rewrite worth more than the words as heard.
    ///
    /// A 30-second recording took 2.5 s with 14 listed words and a prompt that keeps the
    /// speaker's words: 0.9 s to read it and 1.6 s to rewrite it.
    ///
    /// - Returns: Why the entry was left as it was, or nil once it holds the new words.
    func transcribeAgain(_ dictation: Dictation) async -> String? {
        guard canTranscribeAgain else { return "Indite is busy with another dictation." }
        guard let fileName = dictation.recordingFileName, DictationAudioStore.fileExists(named: fileName) else {
            return "The recording of this dictation is no longer on this Mac."
        }
        transcribingAgain = dictation.persistentModelID
        defer { transcribingAgain = nil }
        let started = ContinuousClock.now

        let heard: String
        do {
            heard = try await FileTranscriber.transcribeDictation(
                fileURL: DictationAudioStore.url(forFileNamed: fileName),
                vocabulary: settings.vocabularyHints
            )
        } catch {
            Log.dictation.error("Could not transcribe a dictation again: \(error, privacy: .public)")
            return error.localizedDescription
        }

        let transcript = TextProcessor.process(heard, replacements: settings.wordReplacements)
        guard !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "Nothing was heard in the recording."
        }

        // Snippets as a live dictation expands them: after the AI pass, which never sees
        // their saved text.
        let snippets = settings.snippets
        var text = Snippets.expand(transcript, snippets: snippets).text
        var promptName: String?

        // The prompt chosen in the Rewrite menu now. No app's own choice applies, since
        // the words are going to no app.
        let chosen = settings.selectedPromptId ?? PromptConfiguration.defaultPromptId
        if settings.aiEnabled, chosen != PromptConfiguration.rawPromptId {
            let aiPass = Task { [aiProcessor] in
                try await aiProcessor.process(text: transcript, promptId: chosen)
            }
            do {
                let rewrite = try await withDeadline(seconds: Self.aiDeadline) { try await aiPass.value }
                // A cue the model reworded would lose its saved text, so the words go
                // in as heard, as a live dictation's do.
                if let rewritten = Snippets.expand(rewrite, cuesOf: transcript, snippets: snippets) {
                    text = rewritten.text
                    promptName = aiProcessor.promptConfiguration.prompt(withId: chosen)?.name
                }
            } catch {
                aiPass.cancel()
                let detail = error is DeadlineExceeded
                    ? "The rewrite took longer than \(Int(Self.aiDeadline)) seconds."
                    : error.localizedDescription
                Log.dictation.error("Transcribe Again left the entry as it was, as the rewrite failed: \(detail, privacy: .public)")
                return "The rewrite failed. \(detail)"
            }
        }

        // Deleted while it was being read, by the user or by the history's limit.
        guard let modelContext, !dictation.isDeleted, dictation.modelContext != nil else { return nil }
        dictation.text = text
        // The words heard, as `finishHistory` keeps them.
        dictation.rawText = transcript == text ? nil : transcript
        dictation.promptName = promptName
        modelContext.saveOrLog()
        let took = Int((ContinuousClock.now - started) / .milliseconds(1))
        Log.dictation.notice("Transcribed a dictation again in \(took, privacy: .public) ms")
        return nil
    }

    /// Say in the dictation panel how a dictation ended, or why it did not start.
    ///
    /// Only when the panel is switched on. With it off, notifications are the report,
    /// as before.
    private func report(_ outcome: OverlayOutcome) {
        #if os(macOS)
        guard settings.showDictationOverlay else {
            overlay.hide()
            return
        }
        overlay.showOutcome(outcome)
        #endif
    }

    /// Keep the warmed AI session reading along as the recognizer confirms words.
    ///
    /// Once straight away, on the prompt and the text around the cursor, then every
    /// two seconds until release, new words or not, because a warming fades. After
    /// eight seconds of talking, the first rewritten word came 810 ms after release
    /// when the warming was seven seconds old, and 520 ms when it was two seconds old,
    /// the same as renewing every second. Renewing every second cost the inference
    /// service about 0.05 s of CPU a second.
    ///
    /// Word replacements are applied exactly as they will be at release, so the prefix
    /// matches the request character for character.
    private func startPrefixWarmer() {
        prefixWarmer?.cancel()
        let promptId = rewritePromptId
        prefixWarmer = Task { [weak self] in
            for round in 0... {
                if round > 0 { try? await Task.sleep(for: .seconds(2)) }
                guard let self, self.isRecording, !Task.isCancelled else { return }
                let confirmed = self.engine.currentTranscript
                self.aiProcessor.warmPrefix(
                    promptId: promptId,
                    transcriptSoFar: TextProcessor.process(confirmed, replacements: self.settings.wordReplacements),
                    surroundingText: self.surroundingText
                )
            }
        }
    }

    #if os(macOS)
    // MARK: - Overlay

    private func startOverlayTicker() {
        stopOverlayTicker()

        overlayTicker = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.isRecording else { return }
                self.overlay.update(
                    text: self.engine.currentTranscript + self.engine.volatileText,
                    spectrum: self.engine.spectrum
                )
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }

    private func stopOverlayTicker() {
        overlayTicker?.cancel()
        overlayTicker = nil
    }

    // MARK: - The Mac's Sound

    /// Mute the Mac once the start sound has played through it.
    ///
    /// The start sound plays through the device being muted, so the mute waits for the
    /// sound's length. Waiting no longer is enough: the last 200 ms of every system sound
    /// is at least 51 dB below its peak, 66 dB for Morse, the default, so a headset still
    /// playing out the end when the mute lands loses nothing anyone would hear.
    ///
    /// No meeting can be recording the Mac's sound meanwhile. The engine runs one session
    /// at a time and this dictation holds it, so a meeting cannot start, or resume from a
    /// pause, until the dictation has stopped and `unmute()` has run.
    private func mute(after sound: TimeInterval) {
        // One pending mute at a time. A second one scheduled over the first, without
        // cancelling it, outlived `unmute()` and silenced the Mac after the dictation.
        muteTask?.cancel()
        // The wait covers the audible part of a sound, not all of a long file. Every
        // system sound falls 40 dB within 725 ms (Glass is the slowest; Funk takes
        // 535 ms), while their files run to 1.65 s and 2.16 s, which left the first two
        // seconds of a dictation unmuted.
        let wait = min(sound, Self.longestMuteWait)
        muteTask = Task {
            try? await Task.sleep(for: .seconds(wait))
            // Ended while waiting: `unmute()` has run, and nothing would put this back.
            // A dictation keeps the Mac's sound while it warns about its microphone, so
            // that its alarm is heard; the mute comes back when the warning clears.
            guard !Task.isCancelled, isRecording, !isDelivering, microphoneTrouble == nil else { return }
            OutputMute.mute()
            hasMuted = true
        }
    }

    /// The longest a mute waits for a sound to play out: past the 725 ms in which the
    /// slowest system sound falls 40 dB.
    private static let longestMuteWait: TimeInterval = 0.8

    /// Give the Mac its sound back. Called before the stop sound, so the stop sound is
    /// heard.
    private func unmute() {
        muteTask?.cancel()
        muteTask = nil
        hasMuted = false
        OutputMute.restore()
    }

    // MARK: - The Microphone

    /// Watch the microphone for as long as the dictation records, and warn when it
    /// sends no sound.
    ///
    /// A problem the microphone reports about itself, such as being muted, turned off or
    /// behind a closed lid, is said once half a second passes with no live sound from
    /// it, and never while sound comes through. Its buffers are judged by
    /// `MicrophoneSignal`, whose verdict is read twenty times a second, so a warning
    /// shows within 50 ms of the buffer that decides it. Nothing is said until the
    /// dictation has shown itself, so a tap that turns out not to be a dictation says
    /// nothing.
    ///
    /// - Parameter chosen: The microphone the ranked list chose, or nil for the system
    ///   default. Its name stands in when the device opened has none to give.
    private func watchMicrophone(chosen: AudioInputDevice?) {
        stopWatchingMicrophone()
        lastMicrophoneTrouble = nil
        microphoneProblem = nil
        microphoneFixedAt = nil
        let device = engine.microphone
        microphoneName = device.flatMap(AudioDeviceCatalog.name(of:))
            ?? chosen?.name
            ?? AudioDeviceCatalog.systemDefaultName()
        guard let device else { return }
        checkMicrophoneProblem()

        microphoneWatch = Task { [weak self] in
            let listener = Task { [weak self] in
                for await _ in AudioDeviceCatalog.hearingChanges(of: device) {
                    self?.checkMicrophoneProblem()
                }
            }
            defer { listener.cancel() }

            var verdict = MicrophoneSignal.Verdict.fine
            while !Task.isCancelled {
                guard let self, self.isRecording else { return }
                let signal = self.engine.microphoneSignal
                let latest = signal?.verdict(at: .now) ?? .fine
                // Asked again as the buffers turn silent, which is how a lid closed
                // mid-dictation shows itself, and for as long as a problem lasts, which
                // is how the lid opening does. Neither has a listener.
                if (latest != verdict && latest != .fine) || self.microphoneProblem != nil {
                    self.checkMicrophoneProblem()
                }
                verdict = latest
                if self.isAnnounced {
                    self.showMicrophoneTrouble(self.currentMicrophoneTrouble(verdict: verdict, signal: signal))
                }
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }

    /// Ask the microphone again whether it can hear, and note when a problem goes away.
    private func checkMicrophoneProblem() {
        guard let device = engine.microphone else { return }
        let problem = AudioDeviceCatalog.hearingProblem(of: device)
        if microphoneProblem != nil, problem == nil { microphoneFixedAt = .now }
        microphoneProblem = problem
    }

    /// Why the microphone is not heard now, or nil when it is.
    ///
    /// The microphone's own word comes first, once the buffers bear it out with half a
    /// second of no live sound. Live sound clears it: the microphone hears, whatever it
    /// reports. See `MicrophoneSignal.confirmsReportedProblem(at:)`.
    ///
    /// A fix it reports, such as being unmuted, reaches the buffers a buffer or two
    /// later, and until then they still say silence. The warning it raised waits up to
    /// half a second for sound, rather than turning into "It is sending silence" in
    /// between; after that the buffers decide.
    private func currentMicrophoneTrouble(verdict: MicrophoneSignal.Verdict,
                                          signal: MicrophoneSignal?) -> MicrophoneTrouble? {
        let now = ContinuousClock.now
        if let microphoneProblem, signal?.confirmsReportedProblem(at: now) ?? true {
            return .device(microphoneProblem)
        }
        if case .device = microphoneTrouble, let fixed = microphoneFixedAt,
           (signal?.lastSoundAt ?? fixed) <= fixed, now - fixed < .milliseconds(500) {
            return microphoneTrouble
        }
        return verdict == .fine ? nil : .signal(verdict)
    }

    private func stopWatchingMicrophone() {
        microphoneWatch?.cancel()
        microphoneWatch = nil
        alarmTask?.cancel()
        alarmTask = nil
        microphoneTrouble = nil
        withdrawMicrophoneWarning()
    }

    /// Show a change in the microphone's trouble: a warning in the panel, or a
    /// notification with the panel off, and the alarm when a warning appears.
    ///
    /// Only a change of cause updates a warning already showing: no second alarm, and no
    /// second notification.
    private func showMicrophoneTrouble(_ trouble: MicrophoneTrouble?) {
        guard trouble != microphoneTrouble else { return }
        let appears = microphoneTrouble == nil
        microphoneTrouble = trouble

        guard let trouble else {
            alarmTask?.cancel()
            alarmTask = nil
            overlay.clearWarning()
            withdrawMicrophoneWarning()
            Log.dictation.notice("The microphone warning cleared")
            // The microphone hears again, so the Mac goes quiet again, once an alarm
            // still playing has played out. A warning used to keep the Mac's sound on
            // for the rest of the dictation.
            if settings.muteWhileDictating, !hasMuted { mute(after: Self.longestMuteWait) }
            return
        }

        lastMicrophoneTrouble = trouble
        Log.dictation.notice("The microphone sends no sound: \(trouble.logDescription, privacy: .public)")
        let warning = trouble.warning(microphone: microphoneName)
        if settings.showDictationOverlay {
            overlay.showWarning(warning)
        } else if appears {
            NotificationService.shared.showMicrophoneWarningIfEnabled(warning.detail, title: warning.headline, settings: settings)
            postedMicrophoneWarning = true
        }
        if appears { soundAlarm() }
    }

    /// Withdraw the notification a warning posted with the panel off, when the warning
    /// clears and when the dictation ends.
    private func withdrawMicrophoneWarning() {
        guard postedMicrophoneWarning else { return }
        postedMicrophoneWarning = false
        NotificationService.shared.withdrawMicrophoneWarning()
    }

    /// The error sound, once, as a warning appears.
    ///
    /// It follows the start sound when that is still playing, as the lock sound does.
    /// The Mac's sound comes back first, when there is an alarm to hear: a dictation
    /// that muted the Mac would swallow it. With sounds off, or the error sound set to
    /// None, nothing plays, and a mute already made stays.
    private func soundAlarm() {
        guard AudioFeedbackService.shared.willPlay(.error, settings: settings) else { return }
        unmute()
        let wait = startSoundEnds.map { $0 - .now } ?? .zero
        alarmTask?.cancel()
        alarmTask = Task { [settings] in
            if wait > .zero {
                try? await Task.sleep(for: wait)
                guard !Task.isCancelled else { return }
            }
            AudioFeedbackService.shared.playIfEnabled(.error, settings: settings)
        }
    }
    #endif

    /// What the end of a dictation says when its microphone never sent any sound and
    /// the dictation warned about it while it ran, or nil otherwise.
    ///
    /// A microphone that had no time to start is not blamed: without a warning, the end
    /// says "Nothing was heard" as before.
    private func noSoundOutcome() -> OverlayOutcome? {
        #if os(macOS)
        guard engine.microphoneSignal?.heardSound != true, let trouble = lastMicrophoneTrouble else { return nil }
        let cause = engine.microphone.flatMap(AudioDeviceCatalog.hearingProblem(of:))?.sentence ?? trouble.endingCause
        return .noSoundCame(from: microphoneName, cause: cause)
        #else
        return nil
        #endif
    }

    // MARK: - Safety Cap

    /// Stop a recording that has outlived `settings.maxRecordingSeconds`.
    ///
    /// A hotkey whose key-up never arrives — a lost event, a hung app — would
    /// otherwise record until the disk filled.
    private func startMaxDurationWatchdog() {
        maxDurationTask?.cancel()

        let limit = max(30, settings.maxRecordingSeconds)
        maxDurationTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(limit))
            guard !Task.isCancelled, let self, self.isRecording else { return }
            Log.dictation.notice("Hit the \(limit, privacy: .public)s cap, stopping")
            // Let go of this task before stopping. The stop and the delivery run in it,
            // so the cancel in `stopAndProcess` used to cancel the delivery itself:
            // every sleep in the paste returned at once, and a paste that landed was
            // reported as failed.
            self.maxDurationTask = nil
            await self.stopAndProcess()
        }
    }
}

#if os(macOS)
/// Why a dictation's microphone is not heard.
private enum MicrophoneTrouble: Equatable {
    /// The microphone says it cannot hear: muted, turned off, or behind a closed lid.
    case device(MicrophoneProblem)
    /// Its buffers say so.
    case signal(MicrophoneSignal.Verdict)

    /// What the panel, or a notification, says while the dictation goes on.
    func warning(microphone: String) -> OverlayOutcome {
        switch self {
        case .device(let problem):
            .noSound(from: microphone, yet: false, cause: problem.sentence)
        case .signal(.notStarted(let sentAudio)):
            .noSound(from: microphone, yet: true,
                     cause: sentAudio ? "It is sending silence." : "It has not started sending sound.")
        case .signal(.stalled):
            .noSound(from: microphone, yet: false, cause: "It stopped sending sound.")
        case .signal:
            .noSound(from: microphone, yet: false, cause: "It is sending silence.")
        }
    }

    /// The cause a dictation gives at its end, when this was its last trouble, no sound
    /// ever came, and the microphone says nothing is wrong with it by then.
    var endingCause: String {
        self == .signal(.notStarted(sentAudio: false)) ? "It never started sending sound." : "It sent only silence."
    }

    /// For the log, which never names the microphone: its name can hold the owner's.
    var logDescription: String {
        switch self {
        case .device(let problem): "\(problem)"
        case .signal(let verdict): "\(verdict)"
        }
    }
}
#endif
