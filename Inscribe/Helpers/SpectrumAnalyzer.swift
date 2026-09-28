import Accelerate
import AVFoundation
import Foundation

/// Turns microphone audio into loudness per frequency band, for the dictation band.
///
/// The overlay used to drive every bar from one loudness number and invent the
/// differences between them with a sine wave. This reads them from the sound instead:
/// vowels fill the low bars, an "s" lights the high ones, and a silent room is flat.
///
/// Built and used inside the audio processing task, so it is never shared.
final class SpectrumAnalyzer {

    /// How many bars the band has.
    let bandCount: Int

    /// Samples per transform. 2048 at 48 kHz resolves about 23 Hz, which is finer than
    /// the lowest band needs and still well under one buffer's worth of audio.
    private let size = 2048
    private let log2n: vDSP_Length
    private let setup: FFTSetup
    private let window: [Float]

    /// The FFT bins feeding each bar, worked out once the sample rate is known.
    private var bandBins: [(low: Int, high: Int)] = []
    private var binsForSampleRate: Double = 0

    /// The loudest band heard lately, in decibels. Everything is measured against it,
    /// so the band fits itself to the microphone rather than to a number guessed for
    /// one machine — a quiet headset and a hot built-in mic both fill it.
    private var peak: Double = -40

    /// How far below the peak a band has to fall to read as empty.
    private let range: Double = 38

    /// Each band's level in the room between words, in decibels.
    ///
    /// The peak alone cannot keep a pause dark. It sinks toward the room during a
    /// pause, and the room's low bands sit only about 40 dB under speech, so the room
    /// showed within a second. Replayed through here, 161 logged dictations lit 21 of
    /// the 48 bars in a quiet-room pause. With each band also measured against its own
    /// room level, a pause lights 3. The cost is some height in the lowest bands
    /// during speech, because that is where the room is loudest.
    ///
    /// It starts at 0 dB, above anything a microphone delivers here, and settles onto
    /// the room from above in under a second, so the band opens dark. Starting from
    /// the first buffer would learn the silence that opens most dictations: 141 of 157
    /// logs began with a buffer at or below -90 dB.
    private var room: [Double]

    /// How far a band has to rise above its room level to show. At 8 dB nearly twice
    /// as many bars flickered through a pause, 4.7 of 48 against 2.7.
    private let margin: Double = 10

    init?(bandCount: Int) {
        self.bandCount = bandCount
        self.room = Array(repeating: 0, count: bandCount)
        self.log2n = vDSP_Length(log2(Double(size)))

        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return nil }
        self.setup = setup

        var hann = [Float](repeating: 0, count: size)
        vDSP_hann_window(&hann, vDSP_Length(size), Int32(vDSP_HANN_NORM))
        self.window = hann
    }

    deinit {
        vDSP_destroy_fftsetup(setup)
    }

    /// Loudness per band, 0 to 1, low frequency first.
    func bands(from buffer: AVAudioPCMBuffer) -> [Double] {
        guard let channel = buffer.floatChannelData?[0],
              buffer.frameLength >= AVAudioFrameCount(size) else {
            return Array(repeating: 0, count: bandCount)
        }

        prepareBins(sampleRate: buffer.format.sampleRate)

        // The newest samples, not the oldest. Reading from the front of a buffer
        // longer than the transform analyses audio that is already history, and shows
        // it a buffer late.
        let offset = Int(buffer.frameLength) - size
        var windowed = [Float](repeating: 0, count: size)
        vDSP_vmul(channel + offset, 1, window, 1, &windowed, 1, vDSP_Length(size))

        let half = size / 2
        var real = [Float](repeating: 0, count: half)
        var imaginary = [Float](repeating: 0, count: half)
        var magnitudes = [Float](repeating: 0, count: half)

        real.withUnsafeMutableBufferPointer { realPointer in
            imaginary.withUnsafeMutableBufferPointer { imaginaryPointer in
                var split = DSPSplitComplex(
                    realp: realPointer.baseAddress!,
                    imagp: imaginaryPointer.baseAddress!
                )

                windowed.withUnsafeBufferPointer { samples in
                    samples.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(half))
                    }
                }

                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvabs(&split, 1, &magnitudes, 1, vDSP_Length(half))
            }
        }

        // Average each band's bins, then measure it against the loudest band lately
        // and against its own room level.
        var decibels = [Double](repeating: -120, count: bandCount)
        var loudest = -120.0

        for (index, bin) in bandBins.enumerated() {
            var sum: Float = 0
            for i in bin.low...bin.high {
                sum += magnitudes[i]
            }
            let mean = Double(sum) / Double(bin.high - bin.low + 1) / Double(size)
            let value = mean > 0 ? 20 * log10(mean) : -120
            decibels[index] = value
            loudest = max(loudest, value)
        }

        // Rises with the voice and falls slowly, so a quiet word after a loud one
        // still reads as quieter. Over a longer pause it sinks to the room, which the
        // room levels keep dark.
        peak = loudest > peak
            ? peak + (loudest - peak) * 0.35
            : peak + (loudest - peak) * 0.02

        // Each room level follows a quieter reading quickly and a louder one slowly,
        // so it settles on the room between words and a sentence barely lifts it.
        for index in room.indices {
            let reading = decibels[index]
            room[index] += (reading - room[index]) * (reading < room[index] ? 0.3 : 0.01)
        }

        let floor = peak - range
        return decibels.indices.map { index in
            let bottom = max(floor, room[index] + margin)
            return min(max((decibels[index] - bottom) / range, 0), 1)
        }
    }

    /// Log-spaced bands across the range speech lives in.
    ///
    /// Pitch is heard logarithmically, so equal-width bands would spend forty of the
    /// forty-eight bars on the top two octaves, where a voice has almost nothing.
    private func prepareBins(sampleRate: Double) {
        guard sampleRate != binsForSampleRate else { return }
        binsForSampleRate = sampleRate

        let lowest = 100.0
        let highest = min(7500.0, sampleRate / 2 - 1)
        let binWidth = sampleRate / Double(size)
        let ratio = highest / lowest

        bandBins = (0..<bandCount).map { index in
            let from = lowest * pow(ratio, Double(index) / Double(bandCount))
            let to = lowest * pow(ratio, Double(index + 1) / Double(bandCount))
            let low = max(1, Int(from / binWidth))
            let high = min(size / 2 - 1, max(low, Int(to / binWidth)))
            return (low, high)
        }
    }
}
