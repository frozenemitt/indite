import AVFoundation
import Foundation

public struct AudioData: @unchecked Sendable {
    var buffer: AVAudioPCMBuffer
    var time: AVAudioTime
}
