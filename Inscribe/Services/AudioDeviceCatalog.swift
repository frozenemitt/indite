import Foundation
import Observation

#if os(macOS)
import CoreAudio
import AVFoundation

/// An audio input the user can record from.
struct AudioInputDevice: Identifiable, Hashable, Sendable {
    /// CoreAudio's persistent identifier, stored in settings. Survives reboots and
    /// device renames, unlike the numeric AudioDeviceID.
    let uid: String
    let name: String

    var id: String { uid }

    /// The sentinel meaning "whatever macOS is currently set to".
    static let systemDefaultUID = "default"
}

/// The microphones available right now, kept current for as long as the app runs.
///
/// For the menu bar menu, which is built from state and has no moment of appearing in
/// which to start watching: a microphone plugged in has to be in the list the next
/// time the menu opens.
@MainActor
@Observable
final class AudioInputList {
    static let shared = AudioInputList()

    private(set) var devices: [AudioInputDevice] = AudioDeviceCatalog.inputDevices()
    private(set) var systemDefaultName = AudioDeviceCatalog.systemDefaultName()

    private init() {
        Task { [weak self] in
            for await _ in AudioDeviceCatalog.changes() {
                self?.devices = AudioDeviceCatalog.inputDevices()
                self?.systemDefaultName = AudioDeviceCatalog.systemDefaultName()
            }
        }
    }
}

/// Lists the microphones available to record from.
enum AudioDeviceCatalog {

    /// Every device that has at least one input channel, except private ones.
    static func inputDevices() -> [AudioInputDevice] {
        allDeviceIDs()
            .filter { hasInputChannels($0) && !isPrivateAggregate($0) }
            .compactMap { id in
                guard let uid = stringProperty(kAudioDevicePropertyDeviceUID, for: id),
                      let name = stringProperty(kAudioObjectPropertyName, for: id) else {
                    return nil
                }
                return AudioInputDevice(uid: uid, name: name)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Resolve a stored UID back to a live device, or nil for the system default.
    static func device(forUID uid: String) -> AudioInputDevice? {
        guard uid != AudioInputDevice.systemDefaultUID else { return nil }
        return inputDevices().first { $0.uid == uid }
    }

    /// The name macOS would use right now, for the "System Default" menu entry.
    static func systemDefaultName() -> String {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID
        )
        guard status == noErr else { return "System Default" }
        return stringProperty(kAudioObjectPropertyName, for: deviceID) ?? "System Default"
    }

    /// Yields whenever a device is added or removed, or the default input changes.
    ///
    /// The listener is a C function with a context pointer, not a block. On this system
    /// the block API does not remove a listener: a removed block keeps firing, even when
    /// the same block constant goes to both calls. The removal still returns noErr. The
    /// same function and context in both calls let the HAL match the removal.
    static func changes() -> AsyncStream<Void> {
        AsyncStream { continuation in
            let sink = ChangeSink(continuation)
            let context = Unmanaged.passUnretained(sink).toOpaque()
            let system = AudioObjectID(kAudioObjectSystemObject)
            let selectors = [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultInputDevice]

            for selector in selectors {
                var address = AudioObjectPropertyAddress(
                    mSelector: selector,
                    mScope: kAudioObjectPropertyScopeGlobal,
                    mElement: kAudioObjectPropertyElementMain
                )
                AudioObjectAddPropertyListener(system, &address, ChangeSink.proc, context)
            }

            // Capturing `sink` here keeps it alive until its listeners are gone.
            continuation.onTermination = { _ in
                for selector in selectors {
                    var address = AudioObjectPropertyAddress(
                        mSelector: selector,
                        mScope: kAudioObjectPropertyScopeGlobal,
                        mElement: kAudioObjectPropertyElementMain
                    )
                    AudioObjectRemovePropertyListener(
                        system, &address, ChangeSink.proc, Unmanaged.passUnretained(sink).toOpaque()
                    )
                }
            }
        }
    }

    /// Carries a stream's continuation to the listener function through its context pointer.
    ///
    /// The HAL calls `proc` on its own notification thread. `yield` is thread-safe, and
    /// the stream's consumer resumes on its own actor.
    private final class ChangeSink: Sendable {
        let continuation: AsyncStream<Void>.Continuation

        init(_ continuation: AsyncStream<Void>.Continuation) {
            self.continuation = continuation
        }

        static let proc: AudioObjectPropertyListenerProc = { _, _, _, context in
            Unmanaged<ChangeSink>.fromOpaque(context!).takeUnretainedValue().continuation.yield()
            return noErr
        }
    }

    /// Resolve a UID straight to a device id.
    ///
    /// Unlike `device(forUID:)`, this does not scan the device list — a private
    /// aggregate does not appear there by design, and the meeting input is one.
    static func resolveDeviceID(uid: String) -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var cfUID = uid as CFString
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)

        let status = withUnsafeMutablePointer(to: &cfUID) { pointer in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                UInt32(MemoryLayout<CFString>.size),
                pointer,
                &size,
                &deviceID
            )
        }

        guard status == noErr, deviceID != kAudioObjectUnknown else { return nil }
        return deviceID
    }

    // MARK: - CoreAudio Plumbing

    private static func allDeviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize
        ) == noErr else { return [] }

        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        guard count > 0 else { return [] }

        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, &ids
        ) == noErr else { return [] }

        return ids
    }

    /// Whether a device is an aggregate that exists only inside this app.
    ///
    /// Core Audio builds one as soon as the app records, named
    /// "CADefaultDeviceAggregate-<pid>-0", pairing the default microphone with the
    /// default speakers; the meeting input is another. Both were listed as
    /// microphones. Picking the first saved a device that is gone by the next launch,
    /// so recording quietly fell back to the system default.
    private static func isPrivateAggregate(_ deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioAggregateDevicePropertyComposition,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var composition: Unmanaged<CFDictionary>?
        var size = UInt32(MemoryLayout<Unmanaged<CFDictionary>?>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &composition) == noErr,
              let dictionary = composition?.takeRetainedValue() as? [String: Any] else {
            return false
        }
        return (dictionary[kAudioAggregateDeviceIsPrivateKey] as? Int) == 1
    }

    /// A device is an input if its input scope reports any channels at all.
    private static func hasInputChannels(_ deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &dataSize) == noErr,
              dataSize > 0 else { return false }

        let bufferList = UnsafeMutableRawPointer.allocate(
            byteCount: Int(dataSize),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { bufferList.deallocate() }

        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, bufferList) == noErr else {
            return false
        }

        let list = UnsafeMutableAudioBufferListPointer(
            bufferList.assumingMemoryBound(to: AudioBufferList.self)
        )
        return list.contains { $0.mNumberChannels > 0 }
    }

    private static func stringProperty(
        _ selector: AudioObjectPropertySelector,
        for deviceID: AudioDeviceID
    ) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var value: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)

        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, pointer)
        }

        guard status == noErr else { return nil }
        let result = value as String
        return result.isEmpty ? nil : result
    }
}
#endif
