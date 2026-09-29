import Foundation
import AVFoundation
import Observation
import SwiftData
import os

/// Plays back a saved meeting, and can jump to the moment an utterance was spoken.
///
/// The point of keeping the audio: told that Speaker 2 said something, you can click
/// the line and hear whether that is true. A correction UI you cannot check against
/// the recording is asking you to guess.
@MainActor
@Observable
final class MeetingPlayer {

    private static let log = Logger(subsystem: "com.inscribe.app", category: "MeetingAudio")

    private var player: AVAudioPlayer?
    // Written only on the main actor, but deinit is nonisolated and must stop the
    // timer, so the opt-out sits on the property rather than the whole class.
    nonisolated(unsafe) private var ticker: Timer?

    /// The recording that opened, or nil. A repeated load of the same file does nothing,
    /// and the transcript offers playback only while this is set.
    private(set) var loadedFileName: String?

    private(set) var isPlaying = false
    private(set) var currentTime: TimeInterval = 0
    private(set) var lastError: String?

    /// The utterance being played or paused in, for highlighting it.
    ///
    /// Worked out once per tick here and changed only when playback moves into another
    /// utterance. Each line used to compare itself against `currentTime`, so every line
    /// of the transcript was redrawn four times a second for as long as audio played.
    private(set) var playingUtteranceID: PersistentIdentifier?

    /// Where each utterance sits in the recording, in spoken order.
    @ObservationIgnored private var cues: [(id: PersistentIdentifier, start: TimeInterval, end: TimeInterval)] = []

    deinit {
        ticker?.invalidate()
    }

    // MARK: - Loading

    /// Load a meeting's recording, doing nothing if it is already loaded.
    ///
    /// The file opens off the main thread, so a long recording does not stall the
    /// window. A load whose task was cancelled, because the page went away, installs
    /// no player and reports no error.
    @discardableResult
    func load(fileName: String?) async -> Bool {
        guard let fileName, MeetingAudioStore.fileExists(named: fileName) else {
            unload()
            return false
        }

        guard fileName != loadedFileName else { return true }

        stop()

        do {
            let player = try await Self.open(MeetingAudioStore.url(forFileNamed: fileName))
            guard !Task.isCancelled else { return false }

            self.player = player
            loadedFileName = fileName
            currentTime = 0
            lastError = nil
            return true
        } catch {
            if !Task.isCancelled {
                lastError = error.localizedDescription
            }
            Self.log.error("Could not open the recording: \(error, privacy: .public)")
            unload()
            return false
        }
    }

    /// Open a recording on the concurrent pool rather than the caller's actor.
    @concurrent
    nonisolated static func open(_ url: URL) async throws -> sending AVAudioPlayer {
        let player = try AVAudioPlayer(contentsOf: url)
        player.prepareToPlay()
        return player
    }

    func unload() {
        stop()
        player = nil
        loadedFileName = nil
        currentTime = 0
    }

    // MARK: - Transport

    /// Take the utterances to highlight as playback reaches them.
    ///
    /// Given at each press of play and again after each correction, because a join
    /// deletes the line under the playhead and a split hands part of it to a new line.
    /// The highlight is worked out again at once, since while paused no tick comes to
    /// do it.
    func follow(_ utterances: [Utterance]) {
        cues = utterances.map { ($0.persistentModelID, $0.start, $0.end) }
        updatePlayingUtterance()
    }

    func play() {
        guard let player else { return }
        player.play()
        isPlaying = true
        updatePlayingUtterance()
        startTicking()
    }

    func pause() {
        player?.pause()
        isPlaying = false
        updatePlayingUtterance()
        stopTicking()
    }

    func stop() {
        player?.stop()
        player?.currentTime = 0
        currentTime = 0
        isPlaying = false
        updatePlayingUtterance()
        stopTicking()
    }

    /// Jump to a point in the recording, clamped to its length.
    ///
    /// Timestamps come from the transcript, which can run a fraction past the audio on
    /// the final utterance; seeking past the end silently stops playback instead.
    func seek(to time: TimeInterval) {
        guard let player else { return }
        player.currentTime = max(0, min(time, max(0, player.duration - 0.05)))
        currentTime = player.currentTime
        updatePlayingUtterance()
    }

    /// Jump to an utterance and start playing it.
    func play(from utterance: Utterance) {
        seek(to: utterance.start)
        play()
    }

    /// Find the utterance playback is inside.
    private func updatePlayingUtterance() {
        let time = currentTime
        // Kept through a pause, so the paused line stays marked and keeps its
        // scrubber. Cleared only when playback is stopped back to the start.
        let playing = isPlaying || time > 0
            ? cues.first { time >= $0.start && time < $0.end }?.id
            : nil
        playingUtteranceID = playing
    }

    // MARK: - Progress

    private func startTicking() {
        stopTicking()

        // Four times a second: enough for the highlight to track speech, cheap enough
        // to leave running while a long meeting plays. The transcript hears about a
        // tick only when the utterance changes.
        ticker = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func stopTicking() {
        ticker?.invalidate()
        ticker = nil
    }

    private func tick() {
        guard let player else { return }
        currentTime = player.currentTime

        if !player.isPlaying {
            isPlaying = false
            stopTicking()
        }
        updatePlayingUtterance()
    }
}
