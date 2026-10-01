import Foundation
import FoundationModels
import os
import Observation
import SwiftData

/// Records a meeting: live transcription, speaker diarization, and persistence.
///
/// Distinct from `RecordingCoordinator`, which handles dictation. Dictation is short,
/// disposable and ends by putting text somewhere. A meeting is long, is kept, and ends
/// by being written to the store.
@MainActor
@Observable
final class MeetingRecorder {

    enum State: Equatable {
        case idle
        /// Loading diarization models, which may need downloading on first use.
        case preparing
        case recording
        /// Capture stopped, meeting still open.
        case paused
        /// Aligning and saving after the user stopped.
        case finishing
    }

    // MARK: - Dependencies

    private let engine: TranscriptionEngine
    private let settings: AppSettings
    private let aiProcessor: AIProcessor

    private let diarizer = MeetingDiarizer()
    private let converter = DiarizationAudioConverter()

    /// The other side of a call, when system audio is recorded: its own transcript and
    /// its own speaker separation, merged with the microphone's by time. One
    /// recognizer on a mix of both sides followed whichever was louder.
    private let callDiarizer = MeetingDiarizer(track: "call")
    private let callConverter = DiarizationAudioConverter()
    private let callTranscriber = CallTranscriber()
    /// Whether the session running now records the call as a track of its own.
    private var recordsCall = false
    /// Whether the call's speakers are being separated in this meeting.
    private var callDiarizationActive = false
    /// The call's words from finished sessions, on the meeting clock.
    private var callSegments: [TimedTranscriptSegment] = []
    /// The call's words in the session running now, stamped from the session's start.
    private var liveCall: (segments: [TimedTranscriptSegment], pending: String) = ([], "")
    private var callFeed: AsyncStream<[Float]>.Continuation?
    private var callFeedTask: Task<Void, Never>?
    private let systemAudio = SystemAudioCapture()
    private let systemAudioProbe = SystemAudioLevelProbe()
    private let audioWriter = MeetingAudioWriter()

    /// Whether this meeting has had its one look at the system-audio level.
    private var systemAudioLevelChecked = false

    // MARK: - Observable State

    #if os(macOS)
    /// The small panel that shows the microphone is still hearing the room.
    private let indicator: MeetingIndicatorController

    /// Feeds it while a meeting runs.
    private var indicatorTicker: Task<Void, Never>?
    #endif

    private(set) var state: State = .idle
    private(set) var activeMeeting: Meeting?
    private(set) var lastError: String?

    /// Shown when a microphone change pauses the meeting. Cleared once it no longer
    /// applies, by a resume that starts capture or by the meeting ending.
    private static let microphoneChangedMessage = "The microphone changed, so the meeting paused. Press Resume to carry on with the current microphone."

    /// Whether diarization is running. False means the meeting is still transcribed,
    /// just without speaker labels.
    private(set) var diarizationActive = false

    /// Whether this meeting is recording system playback as well as the microphone.
    private(set) var systemAudioActive = false

    /// The recorded time as text, changed once a second while a meeting is open.
    ///
    /// For the menu bar, which shows the clock beside its icon. `recordedSeconds` is
    /// worked out from the wall clock when asked and tells nobody when it changes, so
    /// a view reading it never redrew.
    private(set) var clockLabel = MeetingExporter.durationLabel(0)

    /// Meetings whose summary is being written.
    ///
    /// Kept here rather than in the view that asked for it. That view is rebuilt for
    /// every meeting selected, so a summary still running looked finished when the user
    /// came back, and Summarize started a second one alongside it.
    private(set) var summarizing: Set<PersistentIdentifier> = []

    /// Why a meeting's last summary failed, until one is asked for again.
    private(set) var summaryErrors: [PersistentIdentifier: String] = [:]

    // MARK: - Session Bookkeeping

    /// Timed runs from every session so far, already shifted onto the meeting clock.
    ///
    /// Stopping the engine resets its own timestamps to zero, so each session's runs
    /// are harvested and offset before the next one starts. Without this a meeting
    /// paused once would attribute its second half against the first half's timeline.
    private var collectedSegments: [TimedTranscriptSegment] = []

    /// Plain transcript accumulated across sessions.
    private var accumulatedTranscript = ""

    /// Where the current session sits on the meeting clock.
    private var sessionOffset: TimeInterval = 0

    /// Audio seconds captured in sessions that have already ended.
    private var completedAudioSeconds: TimeInterval = 0

    /// The start begun by `start()`, while it is still running.
    ///
    /// A quit arriving during "Preparing…" waits on this. Cleaning up the half-built
    /// meeting from outside would hand the start a model the store had dropped.
    private var startTask: Task<Void, Never>?

    /// The save started by `stop()`, while it is still running.
    ///
    /// Quitting can call `stop()` a second time while the first one is mid-save. That
    /// caller waits on this rather than being turned away by the guard, which would
    /// report the meeting written and let the app terminate through the middle of it.
    private var finishTask: Task<Void, Never>?

    /// The pause or resume begun by `pause()` or `resume()`, while it is still running.
    ///
    /// Either one takes a few hundred milliseconds of engine work, and the state does not
    /// change until it is over. Without this, a second click in that window passed the
    /// state guard and ran the same step again: two resumes started the engine twice, and
    /// two pauses harvested the same session twice and doubled every word. A stop or a
    /// quit arriving in that window tore the meeting down underneath the step, which then
    /// finished against a meeting that no longer existed. Pause and resume refuse to begin
    /// while this is set, and stop waits for it.
    ///
    /// Cleared by the task itself as its last act, on the main actor, so a stop waiting on
    /// it never sees it cleared late and never mistakes a finished step for one running.
    private var transitionTask: Task<Void, Never>?

    /// Saves the meeting so far every half minute while it records.
    ///
    /// Everything else reaches the store only at a pause or at stop, so a crash or a
    /// force quit mid-session used to lose the whole transcript.
    private var checkpointTask: Task<Void, Never>?

    /// Pauses the meeting when its microphone goes away.
    @ObservationIgnored private var interruptionObserver: (any NSObjectProtocol)?

    /// Ordered handoff of captured audio to the diarizer.
    ///
    /// The tap runs on the audio thread and the diarizer is an actor, so the handoff
    /// has to be asynchronous. A task per buffer arrives in whatever order the tasks
    /// were scheduled, which scrambles the 16 kHz stream the clustering reads.
    private var diarizerFeed: AsyncStream<[Float]>.Continuation?
    private var diarizerFeedTask: Task<Void, Never>?

    /// Live text: everything kept so far, plus whatever this session has heard.
    ///
    /// Only this meeting's own session counts. Without the owner check, a dictation
    /// taken during a pause appeared in the meeting window as though it were part of
    /// the meeting, and then vanished on stop, because it was never saved into one.
    var liveTranscript: String {
        // With the call as its own track, both sides' finished words in the order they
        // were spoken, then the words each side is still saying.
        if recordsCall || !callSegments.isEmpty {
            let offset = sessionOffset
            let shift = { (segments: [TimedTranscriptSegment]) in
                segments.map { TimedTranscriptSegment(text: $0.text, start: $0.start + offset, end: $0.end + offset) }
            }
            let microphoneNow = engine.owner == .meeting ? shift(engine.timedSegments) : []
            let pending = [engine.owner == .meeting ? engine.volatileText : "", liveCall.pending]
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            return ([Self.merged(collectedSegments + microphoneNow + callSegments + shift(liveCall.segments))] + pending)
                .filter { !$0.isEmpty }
                .joined(separator: " ")
        }

        let current = engine.owner == .meeting
            ? engine.currentTranscript + engine.volatileText
            : ""
        guard !accumulatedTranscript.isEmpty else { return current }
        guard !current.isEmpty else { return accumulatedTranscript }
        return accumulatedTranscript + " " + current
    }

    /// Audio captured so far, including earlier segments of a paused meeting.
    var recordedSeconds: TimeInterval {
        guard state == .recording, let sessionStartedAt else { return completedAudioSeconds }
        return completedAudioSeconds + Date().timeIntervalSince(sessionStartedAt)
    }

    var isRecording: Bool { state == .recording }
    var isPaused: Bool { state == .paused }

    /// Forget the last error, once the user has moved on from the meeting it belongs to.
    func clearError() {
        lastError = nil
    }

    /// Whether a meeting is open, recording or not.
    ///
    /// Read off `state` alone rather than `activeMeeting`, which stays nil until a
    /// meeting actually records: a quit during "Preparing…" has a row in the store and
    /// possibly an open audio file, and answering false there abandons both.
    var hasActiveMeeting: Bool { state != .idle }

    // MARK: - Initialization

    init(engine: TranscriptionEngine, settings: AppSettings, aiProcessor: AIProcessor) {
        self.engine = engine
        self.settings = settings
        self.aiProcessor = aiProcessor
        #if os(macOS)
        self.indicator = MeetingIndicatorController(settings: settings)

        // At launch, before anything can load a speaker model.
        DiarizationModelStore.stayOffline()
        #endif

        // A microphone that changes mid-meeting ends the capture: AirPods connecting, a
        // USB microphone unplugged. Pause rather than carry on recording silence, and
        // say why; Resume picks up whichever microphone is current.
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: TranscriptionEngine.captureInterruptedNotification,
            object: engine,
            queue: .main
        ) { [weak self] note in
            guard (note.userInfo?["owner"] as? TranscriptionEngine.SessionOwner) == .meeting else { return }
            MainActor.assumeIsolated {
                guard let self else { return }
                Log.meetings.error("Microphone changed mid-meeting — pausing")
                Task {
                    await self.pause()
                    self.lastError = Self.microphoneChangedMessage
                }
            }
        }

        // Built once, at launch, before any meeting can start: every meeting still open
        // in the store at this point is one a crash or a force quit never let finish.
        Task { @MainActor [weak self] in
            self?.closeInterruptedMeetings(in: ScribeApp.modelContainer.mainContext)
            // At launch as well as when the Meetings window opens, so a recording
            // whose thirty days are up does not wait on disk for the window.
            MeetingTrash.eraseExpired(in: ScribeApp.modelContainer.mainContext)
        }
    }

    /// Close the meetings a crash or a force quit left open.
    ///
    /// Such a meeting has no end, so every list showed it as still running and its
    /// length growing for ever. Its recording is deleted and the meeting stops pointing
    /// at it. The file was never closed, which leaves AAC audio with no index that
    /// AVAudioPlayer cannot open. Even a readable one could not be played, because a
    /// recording plays only line by line and a meeting that never finished has no
    /// speaker lines.
    ///
    /// A meeting that saved no words and no recorded time is deleted rather than
    /// closed. It crashed while preparing or before its first checkpoint, and closed it
    /// sat in the list as an empty 0:00 meeting for ever. A meeting that recorded time
    /// but saved no words is closed like any other. Its length is the audio recorded up
    /// to the last checkpoint or pause, not counting pauses, whether the room was
    /// silent or the capture failed.
    ///
    /// The end is placed at the start plus the recorded length. Pauses are not
    /// counted, so for a meeting that paused, the end comes before the last moment
    /// captured. The transcript is whatever the last checkpoint or pause saved.
    private func closeInterruptedMeetings(in context: ModelContext) {
        guard state == .idle else { return }

        // The 16 kHz copy kept for speaker separation survives a crash as well, about
        // 230 MB an hour left in the temporary folder, whatever the "Keep the
        // recording" setting says. Nothing can be writing it yet, since no meeting has
        // started.
        MeetingDiarizer.removeLeftoverRecording()

        let open = FetchDescriptor<Meeting>(predicate: #Predicate { $0.endedAt == nil })
        let meetings: [Meeting]
        do {
            meetings = try context.fetch(open)
        } catch {
            Log.meetings.error("Could not look for interrupted meetings: \(error, privacy: .public)")
            return
        }
        guard !meetings.isEmpty else { return }

        var deleted = 0
        for meeting in meetings {
            MeetingAudioStore.delete(fileNamed: meeting.audioFileName)
            meeting.audioFileName = nil

            if meeting.recordedDuration == 0,
               meeting.rawTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                context.delete(meeting)
                deleted += 1
                continue
            }

            meeting.endedAt = meeting.startedAt.addingTimeInterval(meeting.recordedDuration)
            if meeting.hasDefaultTitle {
                meeting.title = meeting.titleFromOpeningWords
            }

            // Checkpoints save the words as heard; the replacements a finished meeting
            // gets at stop() are applied here instead.
            meeting.rawTranscript = TextProcessor.process(
                meeting.rawTranscript,
                replacements: settings.wordReplacements
            )
        }

        context.saveOrLog()
        Log.meetings.notice("""
            Closed \(meetings.count - deleted, privacy: .public) meetings left open \
            by a crash or force quit, deleted \(deleted, privacy: .public) that had \
            saved nothing
            """)
    }

    /// Why the microphone is unavailable to a meeting, named by whoever holds it. Nil
    /// while the engine is idle, and while the meeting itself holds it.
    var microphoneHeldReason: String? {
        guard engine.isBusy else { return nil }
        switch engine.owner {
        case .dictation: return "Inscribe is dictating. Finish that first."
        case .shortcut: return "A shortcut is recording."
        case .meeting, nil: return nil
        }
    }

    #if os(macOS)
    /// Show the panel and keep it fed for as long as the meeting lasts.
    ///
    /// Twenty a second, like the dictation overlay: the band is drawn from the
    /// microphone and anything slower reads as lag.
    ///
    /// Runs for every meeting, whether or not the panel is switched on, and follows
    /// the setting as it changes. Read only when the meeting began, switching the panel
    /// on or off mid-meeting did nothing until the next one.
    private func startIndicator() {
        indicatorTicker?.cancel()

        // The panel's buttons reach back here, so pausing or ending a meeting does not
        // mean going to find the window it belongs to.
        indicator.onPauseOrResume = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.isPaused ? await self.resume() : await self.pause()
            }
        }
        indicator.onStop = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                await self.stop(in: ScribeApp.modelContainer.mainContext)
            }
        }

        indicatorTicker = Task { @MainActor [weak self] in
            var showing = false
            while !Task.isCancelled {
                guard let self, self.state != .idle else { return }

                // Assigned only when the text changes, so the menu bar redraws once a
                // second and not twenty times.
                let clock = MeetingExporter.durationLabel(self.recordedSeconds)
                if self.clockLabel != clock { self.clockLabel = clock }

                // Told to the engine as well as the panel, so the band is computed from
                // the moment the panel is on, not from the next resume.
                if self.engine.owner == .meeting {
                    self.engine.publishesSpectrum = self.settings.showMeetingIndicator
                }

                if self.settings.showMeetingIndicator {
                    if !showing {
                        self.indicator.show()
                        showing = true
                    }
                    self.indicator.update(
                        // The engine's band belongs to whoever owns the engine. During
                        // a pause that can be a dictation, and the meeting's panel drew
                        // its voice as though the meeting were still listening.
                        spectrum: self.engine.owner == .meeting ? self.engine.spectrum : [],
                        seconds: self.recordedSeconds,
                        isPaused: self.isPaused,
                        canPauseOrResume: self.state == .recording
                            || (self.state == .paused && !self.engine.isBusy),
                        microphoneHeldReason: self.isPaused ? self.microphoneHeldReason : nil,
                        error: self.lastError
                    )
                } else if showing {
                    self.indicator.hide()
                    showing = false
                }

                // Only the setting is watched while the panel is off, and a tenth of a
                // second is soon enough for that.
                try? await Task.sleep(for: .milliseconds(showing ? 50 : 100))
            }
        }
    }

    private func stopIndicator() {
        indicatorTicker?.cancel()
        indicatorTicker = nil
        indicator.hide()
    }
    #endif

    // MARK: - Recording

    /// Begin a meeting, creating and inserting the record up front.
    ///
    /// The `Meeting` exists in the store from the first second, so a crash mid-meeting
    /// leaves a titled, findable record rather than nothing.
    func start(in context: ModelContext) async {
        guard state == .idle else { return }

        // Claimed here, before the diarization models load, because that load takes
        // seconds on a cold start. Left unclaimed, the engine looks free for all of
        // it, and a dictation taken in that window wins the race — the meeting's own
        // start then throws and deletes the meeting it had already saved.
        guard engine.reserve(owner: .meeting) else {
            lastError = "Inscribe is already recording. Finish that first."
            AudioFeedbackService.shared.playIfEnabled(.error, settings: settings)
            return
        }

        state = .preparing

        let task = Task { await self.begin(in: context) }
        startTask = task
        await task.value
        startTask = nil
    }

    private func begin(in context: ModelContext) async {
        lastError = nil
        collectedSegments = []
        accumulatedTranscript = ""
        callSegments = []
        sessionOffset = 0
        completedAudioSeconds = 0
        clockLabel = MeetingExporter.durationLabel(0)

        // Inserted up front so a crash mid-meeting still leaves a findable record,
        // but not published until recording actually starts — the window selects
        // whatever activeMeeting names, and a failed start deletes it out from under
        // the detail view.
        let meeting = Meeting()
        context.insert(meeting)
        context.saveOrLog()

        // Diarization is best-effort. Failing to load the models costs speaker labels,
        // not the meeting.
        do {
            try await diarizer.prepare()
            diarizationActive = true
        } catch {
            diarizationActive = false
            lastError = "Speaker separation unavailable: \(error.localizedDescription)"
            Log.meetings.error("Diarizer unavailable: \(error, privacy: .public)")
        }

        engine.collectTimedSegments = true

        // Keep the audio, if the user wants it kept. Started before capture so the
        // first buffer is not lost while the file is being opened.
        keepingAudio = settings.keepMeetingAudio
        if keepingAudio {
            meeting.audioFileName = audioWriter.begin()
            // Saved at once. The file starts filling with the first buffer, and a crash
            // before the next save would leave it on disk with no meeting naming it,
            // where nothing ever finds or deletes it.
            context.saveOrLog()
        }

        systemAudioProbe.reset()
        systemAudioLevelChecked = false

        // Resolved before the tap is installed: building the system-audio device is
        // awaited, and nothing should find the tap attached while it is.
        let inputDeviceUID = await meetingInputDeviceUID()
        await startCallTrack()
        installAudioTap()

        do {
            try await engine.startRecording(
                owner: .meeting,
                vocabulary: settings.vocabularyHints,
                inputDeviceUID: inputDeviceUID,
                publishesSpectrum: settings.showMeetingIndicator
            )
        } catch {
            lastError = error.localizedDescription
            audioWriter.discard()
            await teardown()
            MeetingAudioStore.delete(fileNamed: meeting.audioFileName)
            context.delete(meeting)
            context.saveOrLog()
            activeMeeting = nil
            state = .idle
            AudioFeedbackService.shared.playIfEnabled(.error, settings: settings)
            return
        }

        // The meeting is dated from here, not from when it was inserted. That was before
        // the models loaded and the engine started, seconds earlier on a cold start,
        // and those seconds made its wall-clock length exceed its audio, which reads as
        // a pause that never happened.
        let startedAt = Date()
        sessionStartedAt = startedAt
        meeting.startedAt = startedAt
        activeMeeting = meeting
        state = .recording
        startCheckpoints()
        #if os(macOS)
        startIndicator()
        #endif
        AudioFeedbackService.shared.playIfEnabled(.recordingStarted, settings: settings)
        Log.meetings.notice("Meeting started, diarization: \(self.diarizationActive, privacy: .public)")
    }

    /// Save the meeting so far every half minute, for as long as it is open.
    private func startCheckpoints() {
        checkpointTask?.cancel()
        checkpointTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled, let self, self.state != .idle else { return }
                self.checkpoint()
            }
        }
    }

    /// Write the live transcript and the audio captured so far into the meeting.
    ///
    /// Only while recording: a paused meeting was saved when it paused and has not
    /// changed since, and a finishing one is about to be saved in full.
    private func checkpoint() {
        guard state == .recording, let meeting = activeMeeting else { return }
        meeting.rawTranscript = liveTranscript
        meeting.recordedDuration = recordedSeconds
        meeting.modelContext?.saveOrLog()

        // Checked here as well as at the end, so a failure shows while the meeting is
        // still running rather than only after it has ended.
        reportEngineError()
        reportRecordingFailure()
        checkSystemAudioLevel()
    }

    /// Say so, once, if system audio has been silent through the first minute.
    ///
    /// See `SystemAudioLevelProbe`: a refused permission may record silence rather than
    /// fail.
    private func checkSystemAudioLevel() {
        guard systemAudioActive, !systemAudioLevelChecked, recordedSeconds >= 60 else { return }
        systemAudioLevelChecked = true

        guard !systemAudioProbe.hasHeardSound else { return }
        lastError = "No system audio has been heard in the first minute. If the call is playing, check that Inscribe is allowed under Screen & System Audio Recording in System Settings."
        Log.meetings.notice("System audio silent through the first minute")
    }

    /// Copy a failure the engine recorded into `lastError`.
    ///
    /// The engine keeps a recognizer failure mid-session, or a finalize that overran
    /// its limit and lost the tail, in its own `error`. The meeting never read it, so
    /// the transcript stopped growing, or lost its ending, with nothing on screen to
    /// say so. Read right after each stop, before anything else can start the engine
    /// and clear it, and at each checkpoint while the meeting owns it.
    private func reportEngineError() {
        if let error = engine.error {
            lastError = error.localizedDescription
        }
    }

    /// Add a recording file that failed to open to `lastError`, below whatever is
    /// already shown, such as a recognizer failure that left words out.
    ///
    /// Added only when that line is not already there, so a checkpoint that finds the
    /// same failure again does not repeat it.
    private func reportRecordingFailure() {
        guard let failure = audioWriter.failure else { return }
        let message = "The recording could not be saved: \(failure)"
        guard lastError?.contains(message) != true else { return }
        lastError = lastError.map { "\($0)\n\(message)" } ?? message
    }

    /// The device this meeting records from.
    ///
    /// With system audio on, that is a private aggregate carrying the microphone and
    /// system playback together. Falling back to the plain microphone on failure is
    /// deliberate: half a meeting beats none, and the reason is surfaced rather than
    /// swallowed.
    private func meetingInputDeviceUID() async -> String {
        guard settings.captureSystemAudioInMeetings else {
            systemAudioActive = false
            return settings.inputDeviceUID
        }

        if systemAudio.isActive, let uid = systemAudio.aggregateUID {
            return uid
        }

        do {
            let micUID = settings.inputDeviceUID == AudioInputDevice.systemDefaultUID
                ? nil
                : settings.inputDeviceUID
            // Off the main thread: creating the tap and the aggregate device waits on
            // the audio server, and on the main thread the whole app stalled for it.
            let capture = systemAudio
            let uid = try await Task.detached {
                try capture.start(microphoneUID: micUID)
            }.value
            systemAudioActive = true
            return uid
        } catch {
            systemAudioActive = false
            lastError = error.localizedDescription
            Log.meetings.error("System audio unavailable, microphone only: \(error, privacy: .public)")
            return settings.inputDeviceUID
        }
    }

    /// When the session currently capturing began.
    ///
    /// The recorded length is the sum of these stretches. Measured from the last
    /// transcribed run instead, a meeting that ended in a minute of silence reported
    /// five seconds recorded and called itself paused.
    private var sessionStartedAt: Date?

    /// Whether this meeting is keeping its audio, decided when it started.
    ///
    /// Read once rather than per session: changed during a pause, the setting used to
    /// leave a five minute recording under a ten minute transcript, or switch on a
    /// writer that had never opened a file and record nothing at all.
    private var keepingAudio = false

    /// Route captured audio to the recording file and the diarizer.
    ///
    /// One tap, two consumers: diarization needs 16 kHz mono floats, the recording
    /// wants the buffer untouched. Opening the microphone twice to serve both would
    /// give two clocks and two timelines.
    private func installAudioTap() {
        let diarizer = self.diarizer
        let writer = audioWriter
        let wantsDiarization = diarizationActive
        let wantsAudio = keepingAudio
        let audioConverter = converter
        let probe = systemAudioActive ? systemAudioProbe : nil

        let (feed, continuation) = AsyncStream<[Float]>.makeStream()
        diarizerFeed = continuation
        diarizerFeedTask = Task.detached {
            for await samples in feed {
                await diarizer.append(samples)
            }
        }

        // With the call as its own track, the microphone is channel 0 and the call
        // channel 1, and each goes to its own transcriber and speaker separation.
        let splitsCall = recordsCall
        let diarizesCall = recordsCall && callDiarizationActive
        let callDiarizer = self.callDiarizer
        let callConverter = self.callConverter
        let callTranscriber = self.callTranscriber
        let (callStream, callContinuation) = AsyncStream<[Float]>.makeStream()
        callFeed = callContinuation
        callFeedTask = Task.detached {
            for await samples in callStream {
                await callDiarizer.append(samples)
            }
        }

        engine.audioTap = { buffer in
            probe?.inspect(buffer)
            if wantsAudio {
                writer.append(buffer)
            }
            if wantsDiarization, let audioConverter,
               let samples = audioConverter.floats(from: buffer, channel: splitsCall ? 0 : nil) {
                continuation.yield(samples)
            }
            if splitsCall, let call = buffer.channel(1) {
                callTranscriber.append(call)
                if diarizesCall, let callConverter, let samples = callConverter.floats(from: call) {
                    callContinuation.yield(samples)
                }
            }
        }
    }

    /// Wait for every buffer already captured to reach the diarizer.
    ///
    /// Anything that reads the diarizer's clock or asks it for turns has to run after
    /// the queued audio, or it measures a meeting shorter than the one recorded.
    private func drainDiarizerFeed() async {
        diarizerFeed?.finish()
        await diarizerFeedTask?.value
        diarizerFeed = nil
        diarizerFeedTask = nil
        callFeed?.finish()
        await callFeedTask?.value
        callFeed = nil
        callFeedTask = nil
    }

    /// Give the call a track of its own for the session about to start, when system
    /// audio is being recorded.
    private func startCallTrack() async {
        recordsCall = false
        if systemAudioActive {
            // Separation is best-effort, as for the microphone. Loaded once a meeting;
            // later sessions keep writing the same file.
            if diarizationActive, !callDiarizationActive {
                do {
                    try await callDiarizer.prepare()
                    callDiarizationActive = true
                } catch {
                    Log.meetings.error("Call diarizer unavailable: \(error, privacy: .public)")
                }
            }
            liveCall = ([], "")
            callTranscriber.onChange = { [weak self] segments, pending in
                self?.liveCall = (segments, pending)
            }
            do {
                try await callTranscriber.start(locale: try await engine.resolveSupportedLocale())
                recordsCall = true
            } catch {
                lastError = "The call could not be transcribed on its own: \(error.localizedDescription)"
                Log.meetings.error("Call transcriber unavailable: \(error, privacy: .public)")
            }
        }
        engine.transcribedChannel = recordsCall ? 0 : nil
    }

    /// Collect the call's words from the session that just ended, on the meeting clock.
    private func harvestCall() async {
        guard recordsCall else { return }
        let offset = sessionOffset
        callSegments += await callTranscriber.finish().map {
            TimedTranscriptSegment(text: $0.text, start: $0.start + offset, end: $0.end + offset)
        }
        liveCall = ([], "")
    }

    /// Everything said so far as one text: both sides by time when the call is its own
    /// track, and the microphone's transcript otherwise.
    private var plainTranscript: String {
        callSegments.isEmpty ? accumulatedTranscript : Self.merged(collectedSegments + callSegments)
    }

    /// Runs from both sides in the order they were spoken, as one text.
    private static func merged(_ segments: [TimedTranscriptSegment]) -> String {
        segments
            .sorted { $0.start < $1.start }
            .reduce("") { SpeakerAlignment.joined($0, $1.text) }
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Stop capturing without ending the meeting.
    ///
    /// The engine is torn down rather than left idling, so the microphone indicator
    /// goes out and nothing is recorded while paused. The diarizer is deliberately
    /// left alive: it holds the speaker embeddings that let someone who talked before
    /// the pause keep their identity after it.
    func pause() async {
        guard state == .recording, transitionTask == nil else { return }

        let task = Task {
            await self.performPause()
            self.transitionTask = nil
        }
        transitionTask = task
        await task.value
    }

    private func performPause() async {
        // Disconnected before the stop is awaited, not after. The engine reads
        // `audioTap` once when a session starts, so clearing it here leaves this
        // session's own fan-out intact while making sure the next session — a
        // dictation taken during the pause — is not written into this meeting's
        // recording and fed to its diarizer, shifting every later timestamp.
        engine.audioTap = nil

        // Taken before the stop is awaited, which is when capture ends; see harvestSession.
        let sessionEndedAt = Date()
        let transcript = await engine.stopRecording(owner: .meeting)
        reportEngineError()
        await harvestCall()
        harvestSession(transcript: transcript, endedAt: sessionEndedAt)

        // Turned off only once the session is harvested. The engine reads this flag on
        // every final result, and the stop's finalize step is exactly when the last
        // words before the pause become final; switched off before the stop, they
        // reached the plain transcript and never the speaker transcript.
        engine.collectTimedSegments = false

        await drainDiarizerFeed()

        state = .paused
        AudioFeedbackService.shared.playIfEnabled(.recordingStopped, settings: settings)
        Log.meetings.notice("Paused at \(Int(self.completedAudioSeconds), privacy: .public)s of audio")
    }

    /// Start capturing again, continuing the same meeting.
    func resume() async {
        guard state == .paused, transitionTask == nil else { return }

        let task = Task {
            await self.performResume()
            // A resume that failed has already replaced the microphone-change prompt
            // with its own error. One that succeeded leaves the prompt asking for a
            // Resume that has already happened.
            if self.lastError == Self.microphoneChangedMessage {
                self.lastError = nil
            }
            self.transitionTask = nil
        }
        transitionTask = task
        await task.value
    }

    private func performResume() async {
        // Anchor the new session to the diarizer's clock, which counts only audio it
        // has actually received — the same quantity the transcript timestamps measure.
        sessionOffset = diarizationActive ? await diarizer.receivedSeconds : completedAudioSeconds

        // Resolved before reconnecting, as in begin(): it may await the audio server,
        // and a dictation started meanwhile must not find this meeting's tap attached.
        let inputDeviceUID = await meetingInputDeviceUID()
        await startCallTrack()

        // Reconnected here, having been cleared on pause.
        engine.collectTimedSegments = true
        installAudioTap()

        do {
            try await engine.startRecording(
                owner: .meeting,
                vocabulary: settings.vocabularyHints,
                inputDeviceUID: inputDeviceUID,
                // Passed on every session, not only the first. Left out here, the
                // engine skipped the band after any resume and the panel sat flat for
                // the rest of the meeting.
                publishesSpectrum: settings.showMeetingIndicator
            )
        } catch {
            // Put back the disconnection pause made. The meeting stays paused, and a
            // tap left attached would write the next dictation into this meeting's
            // recording and feed it to its diarizer.
            engine.audioTap = nil
            engine.collectTimedSegments = false
            await drainDiarizerFeed()
            // The call's transcriber was started for this session; nothing was heard.
            _ = await callTranscriber.finish()
            recordsCall = false

            lastError = error.localizedDescription
            AudioFeedbackService.shared.playIfEnabled(.error, settings: settings)
            Log.meetings.error("Could not resume: \(error, privacy: .public)")
            return
        }

        sessionStartedAt = Date()
        state = .recording
        AudioFeedbackService.shared.playIfEnabled(.recordingStarted, settings: settings)
        Log.meetings.notice("Resumed at offset \(Int(self.sessionOffset), privacy: .public)s")
    }

    /// Move this session's results onto the meeting clock.
    ///
    /// - Parameter endedAt: When capture stopped, taken before the engine's stop was
    ///   awaited. The stop ends capture at once and then spends up to several seconds
    ///   finalizing; measured after it, every session counted seconds that were never
    ///   recorded, and an unpaused meeting showed a "recorded" figure as if paused.
    private func harvestSession(transcript: String, endedAt: Date) {
        let offset = sessionOffset

        collectedSegments.append(contentsOf: engine.timedSegments.map { segment in
            TimedTranscriptSegment(
                text: segment.text,
                start: segment.start + offset,
                end: segment.end + offset
            )
        })

        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            accumulatedTranscript += accumulatedTranscript.isEmpty ? trimmed : " " + trimmed
        }

        // Wall clock across the stretch that was actually capturing. Nothing is
        // recorded while paused, so this is both the length of the audio file and the
        // clock the segment offsets are placed on.
        if let sessionStartedAt {
            completedAudioSeconds += endedAt.timeIntervalSince(sessionStartedAt)
        }
        sessionStartedAt = nil

        // Written through and saved on every harvest, not only at stop(). A crash or a
        // kill during a pause then costs nothing, and one while recording costs no more
        // than the time since the last checkpoint.
        activeMeeting?.rawTranscript = plainTranscript
        activeMeeting?.recordedDuration = completedAudioSeconds
        activeMeeting?.modelContext?.saveOrLog()
    }

    /// End the meeting, align speakers to text, and save.
    func stop(in context: ModelContext) async {
        // Let a start in flight finish first. It ends by either adopting its meeting or
        // deleting it, so once it returns this is an ordinary stop of a recording
        // meeting, or there is nothing left to stop.
        if state == .preparing {
            await startTask?.value
        }

        // Likewise a pause or resume in flight. Each ends in a settled state, recording
        // or paused, and this stop then ends the meeting from there. Looped because
        // another click can begin a new step in the moment between one finishing and
        // this carrying on.
        while let transition = transitionTask {
            await transition.value
        }

        // Quitting calls this while the Stop button's save is still running. That
        // caller has to wait for the save in flight; turning it away here reports a
        // meeting written that is still halfway through being written.
        if state == .finishing {
            await finishTask?.value
            return
        }

        guard state == .recording || state == .paused, let meeting = activeMeeting else { return }

        let wasRecording = state == .recording
        state = .finishing
        // Hidden now, not when the save ends. The panel cannot tell a meeting that is
        // saving from one that records, and for the whole save it showed a red record
        // glyph, a frozen clock, and Pause and Stop buttons that did nothing.
        #if os(macOS)
        stopIndicator()
        #endif

        let task = Task { await self.finish(meeting, wasRecording: wasRecording, in: context) }
        finishTask = task
        await task.value
        finishTask = nil
    }

    private func finish(_ meeting: Meeting, wasRecording: Bool, in context: ModelContext) async {
        // The meeting ends now, when stop was asked for. Taken after the engine's stop
        // and the last diarizer chunk, the end ran seconds past the audio, and an
        // unpaused meeting's two lengths disagreed as though it had been paused.
        let stoppedAt = Date()

        // A meeting stopped while a microphone change had it paused has nothing left to
        // resume, and the prompt to press Resume would stay on the finished meeting.
        if lastError == Self.microphoneChangedMessage {
            lastError = nil
        }

        if wasRecording {
            AudioFeedbackService.shared.playIfEnabled(.recordingStopped, settings: settings)

            // Disconnected before the stop is awaited, for the same reason as in
            // pause(): this session keeps its own fan-out, and anything started
            // afterwards must not be recorded into this meeting.
            engine.audioTap = nil

            let transcript = await engine.stopRecording(owner: .meeting)
            reportEngineError()
            await harvestCall()
            harvestSession(transcript: transcript, endedAt: stoppedAt)

            // After the harvest, as in pause(): the stop is what makes the last words
            // final, and they are only collected while this is on.
            engine.collectTimedSegments = false
        }

        // Read before finish(), which clears it.
        reportRecordingFailure()

        await drainDiarizerFeed()
        var turns: [SpeakerTurn] = []
        if diarizationActive {
            do {
                let lost = await diarizer.lostSeconds
                turns = try await diarizer.finish()
                if lost >= 1, !turns.isEmpty {
                    let gap = "Speaker separation missed \(MeetingExporter.durationLabel(lost)) of audio that could not be written to disk, so speakers after that point may be attributed early."
                    lastError = lastError.map { "\($0)\n\(gap)" } ?? gap
                }
            } catch {
                // Added below whatever is already shown rather than replacing it. The
                // microphone prompt was cleared above, and what remains still describes
                // this meeting, such as a recognizer failure that left words out.
                let separation = "Speaker separation failed: \(error.localizedDescription)"
                lastError = lastError.map { "\($0)\n\(separation)" } ?? separation
                Log.meetings.error("Speaker separation failed: \(error, privacy: .public)")
            }
        }

        meeting.endedAt = stoppedAt
        meeting.recordedDuration = completedAudioSeconds
        meeting.audioFileName = audioWriter.finish()
        meeting.rawTranscript = TextProcessor.process(
            plainTranscript,
            replacements: settings.wordReplacements
        )

        var callTurns: [SpeakerTurn] = []
        if callDiarizationActive {
            do {
                callTurns = try await callDiarizer.finish()
            } catch {
                let separation = "Speaker separation on the call failed: \(error.localizedDescription)"
                lastError = lastError.map { "\($0)\n\(separation)" } ?? separation
                Log.meetings.error("Call speaker separation failed: \(error, privacy: .public)")
            }
        }

        let attributed = meeting.applyAttribution(
            tracks: callSegments.isEmpty
                ? [(collectedSegments, turns)]
                : [(collectedSegments, turns), (callSegments, callTurns)],
            vocabulary: settings.vocabularyHints,
            replacements: settings.wordReplacements,
            in: context
        )

        // A recording plays only line by line, so a meeting without speaker lines has
        // nothing that can play it. Kept, it filled about 30 MB an hour of disk that no
        // part of the app could reach, and the meeting never said "no recording kept".
        if !attributed {
            MeetingAudioStore.delete(fileNamed: meeting.audioFileName)
            meeting.audioFileName = nil
        } else if let recording = meeting.audioFileName {
            // The recognizer's timing for every word, beside the recording, so a click
            // on a word in the transcript can find the moment it was said.
            MeetingWordTimings.save(tracks: [collectedSegments, callSegments], forRecording: recording)
        }

        context.saveOrLog()
        await teardown()

        state = .idle
        activeMeeting = nil
        AudioFeedbackService.shared.playIfEnabled(.processingComplete, settings: settings)

        // After the meeting is saved and the recorder is free, and in a task of its
        // own. A quit waits for stop(), and must not wait for a summary; a meeting
        // started straight after must not wait for one either.
        Task { await self.writeTitleAndSummary(for: meeting, in: context) }

        // The title is the user's own words, so it is left private and the system
        // redacts it. The counts are what make the line worth keeping.
        Log.meetings.notice("""
            saved "\(meeting.title)" — \
            \(meeting.utterances.count, privacy: .public) utterances, \
            \(meeting.speakers.count, privacy: .public) speakers
            """)
    }

    // MARK: - Title

    /// Give a meeting that has just ended a title, and a summary when it is long
    /// enough to need one.
    ///
    /// The title is written even with the setting off, from the first words spoken:
    /// "New Meeting" a dozen times over is the list this replaces.
    private func writeTitleAndSummary(for meeting: Meeting, in context: ModelContext) async {
        await writeTitle(for: meeting, in: context, usingModel: settings.summarizeMeetingsAtEnd)

        // A summary of a few sentences is those sentences again.
        guard settings.summarizeMeetingsAtEnd, meeting.rawTranscript.count >= Self.shortestSummarized else { return }
        await summarize(meeting, in: context)
    }

    /// Characters of transcript below which a meeting is left unsummarized, about a
    /// minute of speech.
    private static let shortestSummarized = 800

    /// Replace a default title with one that says what the meeting was about.
    ///
    /// Only a default title: one the user typed, during the meeting or since, stays.
    private func writeTitle(for meeting: Meeting, in context: ModelContext, usingModel: Bool) async {
        guard meeting.hasDefaultTitle else { return }

        var title = meeting.titleFromOpeningWords
        // A few words name themselves better than a model can.
        if usingModel, meeting.rawTranscript.count >= 200 {
            do {
                title = try await aiProcessor.title(forMeetingTranscript: meeting.rawTranscript)
            } catch {
                Log.meetings.error("Could not write a title, using the opening words: \(error, privacy: .public)")
            }
        }

        // Checked again after the wait: the user may have typed one meanwhile, or
        // deleted the meeting.
        guard !meeting.isDeleted, meeting.modelContext != nil, meeting.hasDefaultTitle else { return }
        meeting.title = title
        context.saveOrLog()
    }

    // MARK: - Summary

    /// Generate an AI summary for a finished meeting.
    ///
    /// The on-device model reads only so much at once, and a transcript of more than
    /// about a quarter of an hour used to exceed it and fail. A transcript too long for
    /// one request is summarized in pieces that each fit, and the piece summaries are
    /// then summarized together, as many rounds as it takes to fit in one request.
    func summarize(_ meeting: Meeting, in context: ModelContext) async {
        let id = meeting.persistentModelID
        guard summarizing.insert(id).inserted else { return }
        summaryErrors[id] = nil
        defer { summarizing.remove(id) }

        // A meeting from before titles were written gets one when it is summarized.
        await writeTitle(for: meeting, in: context, usingModel: true)

        do {
            var text = MeetingExporter.plainText(meeting)
            guard !text.isEmpty else { return }

            let budget = Self.summaryInputBudget

            while true {
                let tokens = await Self.estimatedTokens(in: text)
                guard tokens > budget else { break }

                // Characters per token for this text, measured rather than assumed,
                // with a tenth held back because the pieces will not all tokenize alike.
                let charactersPerToken = Double(text.count) / Double(max(tokens, 1))
                let pieceLimit = max(1, Int(Double(budget) * charactersPerToken * 0.9))

                var summaries: [String] = []
                for piece in Self.pieces(of: text, limit: pieceLimit) {
                    // The built-in Summarize prompt, not the one chosen for dictation.
                    // That is usually a cleanup pass, and handed back the transcript
                    // tidied, not summarized.
                    summaries.append(try await aiProcessor.process(
                        text: piece,
                        promptId: PromptConfiguration.summarizePromptId
                    ))
                    guard !meeting.isDeleted, meeting.modelContext != nil else { return }
                }

                // A round that fails to shorten the text would repeat for ever. The
                // last request below then reports the overflow as it always has.
                let combined = summaries.joined(separator: "\n\n")
                guard combined.count < text.count else { break }
                text = combined
            }

            let summary = try await aiProcessor.process(
                text: text,
                promptId: PromptConfiguration.summarizePromptId
            )

            // The summary takes long enough that the meeting can be deleted while it
            // runs. Once that deletion is saved, `isDeleted` reads false again and only
            // the missing context shows the meeting is gone.
            guard !meeting.isDeleted, meeting.modelContext != nil else { return }

            meeting.summary = summary
            context.saveOrLog()
        } catch {
            summaryErrors[id] = error.localizedDescription
        }
    }

    /// Tokens of transcript one summary request may carry.
    ///
    /// Read from the model rather than fixed: the context is 4,096 tokens on macOS 26
    /// and larger on later systems and other devices. The request also carries the
    /// instructions, the prompt template and the output schema, about 500 tokens held
    /// back here, and the reply comes out of the same context. The prompt asks for a
    /// summary a fifth to a third of the length it reads, so three fifths of what is
    /// left goes to the transcript and two fifths to the reply.
    private static var summaryInputBudget: Int {
        max(256, (SystemLanguageModel.default.contextSize - 512) * 3 / 5)
    }

    /// How many tokens the model will see in `text`.
    ///
    /// Counted by the model where the system can do that, from macOS 26.4. Before that,
    /// or if counting fails, estimated at three characters a token: English prose runs
    /// nearer four, but timestamps, names and numbers tokenize worse, and an estimate
    /// that runs high costs an extra piece where one that runs low costs the summary.
    private static func estimatedTokens(in text: String) async -> Int {
        if #available(macOS 26.4, iOS 26.4, *),
           let counted = try? await SystemLanguageModel.default.tokenCount(for: text) {
            return counted
        }
        return text.count / 3
    }

    /// Cut `text` into pieces of at most `limit` characters.
    ///
    /// Cut between utterances, which the exported transcript separates with a blank
    /// line, so no line is split from its speaker. A single utterance longer than the
    /// limit, or a transcript with no speakers at all, is cut between words.
    private static func pieces(of text: String, limit: Int) -> [String] {
        var pieces: [String] = []
        var current = ""
        var currentLength = 0

        func add(_ part: String, length: Int, separator: String) {
            if currentLength > 0, currentLength + separator.count + length > limit {
                pieces.append(current)
                current = ""
                currentLength = 0
            }
            if currentLength > 0 {
                current += separator
                currentLength += separator.count
            }
            current += part
            currentLength += length
        }

        for paragraph in text.components(separatedBy: "\n\n") {
            let length = paragraph.count
            if length <= limit {
                add(paragraph, length: length, separator: "\n\n")
            } else {
                for (index, word) in paragraph.split(separator: " ").enumerated() {
                    add(String(word), length: word.count, separator: index == 0 ? "\n\n" : " ")
                }
            }
        }

        if currentLength > 0 {
            pieces.append(current)
        }
        return pieces
    }

    // MARK: - Teardown

    private func teardown() async {
        checkpointTask?.cancel()
        checkpointTask = nil
        engine.audioTap = nil
        engine.collectTimedSegments = false
        await drainDiarizerFeed()
        await diarizer.reset()
        await callDiarizer.reset()
        _ = await callTranscriber.finish()
        engine.transcribedChannel = nil
        recordsCall = false
        callDiarizationActive = false

        // The tap and its aggregate outlive the app if not destroyed, so this runs on
        // every exit path rather than only the successful one. Off the main thread for
        // the same reason building them is.
        let capture = systemAudio
        await Task.detached { capture.stop() }.value
        systemAudioActive = false
        diarizationActive = false
    }
}
