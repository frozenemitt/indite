import AVFoundation
import Foundation
import FluidAudio
import os

/// Listens for the words on the vocabulary list in the audio itself.
///
/// Apple's recognizer ignores vocabulary hints, and its second guesses hold the right
/// word only some of the time. A small speech model needs neither: NVIDIA's Parakeet
/// CTC 110M, run by FluidAudio on the Neural Engine, scores how well each listed word
/// fits each stretch of the recording. Where one fits and the recognizer was unsure of
/// what it wrote there, the listed word goes in; see `Vocabulary.applySpotted`.
///
/// On 32 sentences in the user's own voice, listed words came out right 24 times in
/// 29 with this and the other vocabulary fixes, against 19 without it and 13 from the
/// recognizer alone. It put in no wrong word and changed none of 9 sentences that used
/// a sound-alike correctly ("up to Maine", "our cloud bill", "Nora").
///
/// The model reads fixed 15-second windows, and a read takes about 0.11 s whatever the
/// length. Windows are read while the user is still speaking, so the release waits for
/// one read however long the dictation, and that one runs while the recognizer
/// finishes.
///
/// The model is not bundled. Without it in `modelDirectory` the spotter stays off and
/// the other vocabulary fixes still run.
final class VocabularySpotter: Sendable {
    static let shared = VocabularySpotter()

    static let modelDirectory = URL.applicationSupportDirectory
        .appending(path: "Inscribe/SpotterModel/parakeet-ctc-110m-coreml", directoryHint: .isDirectory)

    struct Detection: Sendable {
        let term: String
        let score: Float
        let start: Double
        let end: Double
    }

    private struct Loaded: Sendable {
        let spotter: CtcKeywordSpotter
        let tokenizer: CtcTokenizer
    }

    private let loaded = OSAllocatedUnfairLock<Loaded?>(initialState: nil)
    private static let log = Logger(subsystem: "com.inscribe.app", category: "Vocabulary")

    /// Load the model. The first load after an install takes about 20 s while macOS
    /// prepares it for the Neural Engine; later ones take a fraction of a second.
    func load() async {
        guard loaded.withLock({ $0 == nil }) else { return }
        guard FileManager.default.fileExists(atPath: Self.modelDirectory.path) else {
            Self.log.notice("No spotter model at \(Self.modelDirectory.path, privacy: .public); listed words are not listened for")
            return
        }
        let started = ContinuousClock.now
        do {
            // Never fetch: the model is put in place once, and loading it must not reach
            // for the network.
            ModelHub.offlineMode = true
            let models = try await CtcModels.load(from: Self.modelDirectory, variant: .ctc110m)
            let tokenizer = try await CtcTokenizer.load(from: Self.modelDirectory)
            let spotter = CtcKeywordSpotter(models: models)
            // Read once, so the first dictation does not pay for the model's first run.
            _ = try? await spotter.spotKeywordsWithLogProbs(
                audioSamples: [Float](repeating: 0, count: 16_000), customVocabulary: CustomVocabularyContext(terms: []))
            loaded.withLock { $0 = Loaded(spotter: spotter, tokenizer: tokenizer) }
            Self.log.notice("Spotter ready in \(ContinuousClock.now - started, privacy: .public)")
        } catch {
            Self.log.error("Could not load the spotter: \(error, privacy: .public)")
        }
    }

    /// A session for one dictation, or nothing when the model is not loaded.
    func session() -> Session? {
        loaded.withLock { $0 }.map { Session(spotter: $0.spotter, tokenizer: $0.tokenizer) }
    }

    /// One dictation's audio, read in windows as it arrives.
    final class Session: @unchecked Sendable {
        private static let rate = 16_000
        /// The model's fixed window, and how far each read moves on from the last.
        /// The overlap lets every word be read with some audio either side of it.
        private static let window = 15 * rate
        private static let step = 13 * rate
        /// Frames this close to a window's edge are left to the next read, which hears
        /// what follows them.
        private static let margin = 1 * rate

        private let spotter: CtcKeywordSpotter
        private let tokenizer: CtcTokenizer
        private let lock = NSLock()
        private var samples: [Float] = []
        /// The model's reading of each frame since the start of the recording.
        private var frames: [[Float]] = []
        private var frameDuration: Double = 0
        private var nextWindowEnd = Session.window
        private var reading: Task<Void, Never>?
        private let converter = BufferConverter()
        private let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!

        fileprivate init(spotter: CtcKeywordSpotter, tokenizer: CtcTokenizer) {
            self.spotter = spotter
            self.tokenizer = tokenizer
        }

        /// Take in the next stretch of audio, as the recognizer is fed it.
        func append(_ buffer: AVAudioPCMBuffer) {
            guard let mono = resampled(buffer) else { return }
            lock.withLock {
                samples.append(contentsOf: mono)
                startReadIfDue()
            }
        }

        /// Read what is left and find the listed terms in the whole recording.
        func finish(terms: [String]) async -> [Detection] {
            // A window already being read finishes first: its frames are wanted.
            while let running = lock.withLock({ reading }) { await running.value }

            let (total, end) = lock.withLock { (samples.count, frames.count) }
            guard total > 0 else { return [] }
            let start = max(0, total - Self.window)
            // From the first frame no earlier read covered, or from a second into this
            // window, whichever comes first.
            let covered = Double(end) * frameDuration
            let keepFrom = start == 0 ? 0 : min(Double(start + Self.margin) / Double(Self.rate), covered)
            await read(from: start, to: total, keepingFrom: keepFrom, keepingTo: Double(total) / Double(Self.rate))

            let (logProbs, duration) = lock.withLock { (frames, frameDuration) }
            guard !logProbs.isEmpty, duration > 0 else { return [] }
            let vocabulary = CustomVocabularyContext(terms: terms.compactMap { term in
                let ids = tokenizer.encode(term)
                return ids.isEmpty ? nil : CustomVocabularyTerm(text: term, ctcTokenIds: ids)
            })
            // Every candidate comes back; `Vocabulary.applySpotted` decides which count.
            let result = spotter.spotKeywordsFromLogProbs(
                logProbs: logProbs, frameDuration: duration, customVocabulary: vocabulary, minScore: -25)
            return result.detections.map {
                Detection(term: $0.term.text, score: $0.score, start: $0.startTime, end: $0.endTime)
            }
        }

        // MARK: - Reading

        /// Start reading the next full window in the background, if the audio for it is in.
        /// Called with the lock held.
        private func startReadIfDue() {
            guard reading == nil, samples.count >= nextWindowEnd else { return }
            let end = nextWindowEnd
            let start = end - Self.window
            nextWindowEnd += Self.step
            reading = Task.detached(priority: .utility) { [self] in
                let keepFrom = start == 0 ? 0 : Double(start + Self.margin) / Double(Self.rate)
                await read(from: start, to: end, keepingFrom: keepFrom,
                           keepingTo: Double(end - Self.margin) / Double(Self.rate))
                lock.withLock {
                    reading = nil
                    startReadIfDue()
                }
            }
        }

        /// Run the model on samples `start..<end` and keep its frames between two times.
        private func read(from start: Int, to end: Int, keepingFrom keepFrom: Double, keepingTo keepTo: Double) async {
            let chunk = lock.withLock { Array(samples[start..<end]) }
            guard let result = try? await spotter.spotKeywordsWithLogProbs(
                audioSamples: chunk, customVocabulary: CustomVocabularyContext(terms: [])),
                result.frameDuration > 0 else { return }
            let offset = Double(start) / Double(Self.rate)
            lock.withLock {
                frameDuration = result.frameDuration
                for (index, frame) in result.logProbs.enumerated() {
                    let time = offset + Double(index) * result.frameDuration
                    guard time >= keepFrom - 1e-6, time < keepTo else { continue }
                    let global = Int((time / result.frameDuration).rounded())
                    if global < frames.count {
                        frames[global] = frame
                    } else if global == frames.count {
                        frames.append(frame)
                    }
                }
            }
        }

        /// The buffer as 16 kHz mono floats, which the model reads.
        private func resampled(_ buffer: AVAudioPCMBuffer) -> [Float]? {
            if buffer.format.commonFormat == .pcmFormatInt16, buffer.format.sampleRate == 16_000,
               buffer.format.channelCount == 1, let data = buffer.int16ChannelData {
                return UnsafeBufferPointer(start: data[0], count: Int(buffer.frameLength)).map { Float($0) / 32_768 }
            }
            guard let output = try? converter.convertBuffer(buffer, to: format),
                  let data = output.floatChannelData else { return nil }
            return Array(UnsafeBufferPointer(start: data[0], count: Int(output.frameLength)))
        }
    }
}
