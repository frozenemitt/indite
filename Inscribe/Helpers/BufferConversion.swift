@preconcurrency import AVFoundation
import Foundation

class BufferConverter {
    enum Error: Swift.Error {
        case failedToCreateConverter
        case failedToCreateConversionBuffer
        case conversionFailed(NSError?)
    }

    private var converter: AVAudioConverter?
    func convertBuffer(_ buffer: AVAudioPCMBuffer, to format: AVAudioFormat) throws
        -> AVAudioPCMBuffer
    {
        let inputFormat = buffer.format
        guard inputFormat != format else {
            return buffer
        }

        if converter == nil || converter?.outputFormat != format || converter?.inputFormat != inputFormat {
            converter = AVAudioConverter(from: inputFormat, to: format)
            converter?.primeMethod = .none  // Sacrifice quality of first samples in order to avoid any timestamp drift from source
            // Mix every channel in. Without this, reducing the channel count keeps only
            // the first channel, so a microphone on input 2 of an interface, or the
            // system audio mixed into a meeting's device, is never heard.
            converter?.downmix = true
        }

        guard let converter else {
            throw Error.failedToCreateConverter
        }

        let sampleRateRatio = converter.outputFormat.sampleRate / converter.inputFormat.sampleRate
        let scaledInputFrameLength = Double(buffer.frameLength) * sampleRateRatio
        let frameCapacity = AVAudioFrameCount(scaledInputFrameLength.rounded(.up))
        guard
            let conversionBuffer = AVAudioPCMBuffer(
                pcmFormat: converter.outputFormat, frameCapacity: frameCapacity)
        else {
            throw Error.failedToCreateConversionBuffer
        }

        var nsError: NSError?
        // A plain flag is enough: convert calls the input block synchronously on this thread.
        var consumed = false

        let status = converter.convert(to: conversionBuffer, error: &nsError) { _, inputStatus in
            if consumed {
                inputStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            inputStatus.pointee = .haveData
            return buffer
        }

        guard status != .error else {
            throw Error.conversionFailed(nsError)
        }

        return conversionBuffer
    }
}
