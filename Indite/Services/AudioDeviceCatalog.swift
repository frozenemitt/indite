import Foundation
import Observation

/// A microphone Indite has seen: one connected now, or one kept in the ranked list
/// after it was unplugged.
struct AudioInputDevice: Identifiable, Hashable, Sendable {
    /// CoreAudio's persistent identifier, stored in settings. Survives reboots and
    /// device renames, unlike the numeric AudioDeviceID.
    let uid: String
    /// Its name as macOS last showed it.
    let name: String
    let kind: Kind

    var id: String { uid }

    /// The sentinel meaning "whatever macOS is currently set to".
    static let systemDefaultUID = "default"

    /// The Mac's own microphone, one slow to start, or any other. Kept with an unplugged
    /// microphone, so Settings can still tell what it was.
    enum Kind: String, Sendable {
        /// The Mac's own microphone.
        case builtIn
        /// Bluetooth, or an iPhone's through Continuity: seconds to start, and
        /// Bluetooth sends phone-call-quality sound.
        case slowToStart
        /// Anything else: USB, a headset in the headphone jack, a virtual device.
        case other
    }
}

/// Why a microphone cannot hear right now.
enum MicrophoneProblem: Equatable, Sendable {
    /// It is not connected.
    case missing
    case muted
    /// Its input volume is at zero, on a device where zero is silence.
    case volumeOff
    /// It is the built-in microphone, and the lid is closed. A Mac laptop disconnects
    /// that microphone in hardware while the lid is shut.
    case lidClosed

    /// The cause, as the dictation panel says it under the headline.
    var sentence: String {
        switch self {
        case .missing: "It is not connected."
        case .muted: "It is muted."
        case .volumeOff: "Its input volume is at zero."
        case .lidClosed: "The lid is closed."
        }
    }

    /// The cause in a few words, for the log.
    var reason: String {
        switch self {
        case .missing: "not connected"
        case .muted: "muted"
        case .volumeOff: "volume at zero"
        case .lidClosed: "lid closed"
        }
    }
}

#if os(macOS)
import CoreAudio
import AVFoundation
import IOKit
import os

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

    /// Every device that has at least one input channel, except private ones and
    /// virtual ones, in the order the system lists them.
    ///
    /// A virtual device such as Microsoft Teams Audio carries an app's sound, not a
    /// voice, and it is always connected, so ranked below the Mac's microphone it was
    /// chosen whenever the lid was closed and nothing else could hear: the dictation
    /// recorded silence and warned. Jonathan had them left out on 2026-11-10; the
    /// Mac's own sound is recorded for meetings another way.
    static func inputDevices() -> [AudioInputDevice] {
        allDeviceIDs()
            .filter { hasInputChannels($0) && !isPrivateAggregate($0) && !isVirtual($0) }
            .compactMap { id in
                guard let uid = stringProperty(kAudioDevicePropertyDeviceUID, for: id),
                      let name = stringProperty(kAudioObjectPropertyName, for: id) else {
                    return nil
                }
                return AudioInputDevice(uid: uid, name: name, kind: kind(of: id))
            }
    }

    /// Resolve a stored UID back to a live device, or nil for the system default.
    static func device(forUID uid: String) -> AudioInputDevice? {
        guard uid != AudioInputDevice.systemDefaultUID else { return nil }
        return inputDevices().first { $0.uid == uid }
    }

    /// The microphone a recording starting now uses: the first in the user's order that
    /// can hear, or the system default when none can.
    ///
    /// The one place the ranked list becomes a device. Dictations, meetings and the
    /// shortcut record from what it chooses, and the menu names it. The microphone
    /// warning watches the device the capture opens for that choice.
    static func microphone(for order: [AudioInputDevice]) -> MicrophoneOrder.Choice {
        MicrophoneOrder.choose(from: order, connected: inputDevices()) { uid in
            guard let device = resolveDeviceID(uid: uid) else { return .missing }
            return hearingProblem(of: device)
        }
    }

    /// `microphone(for:)` for a recording about to start, with the choice in the log.
    static func microphoneForRecording(_ order: [AudioInputDevice]) -> MicrophoneOrder.Choice {
        let choice = microphone(for: order)
        Log.audio.notice("\(choice.summary, privacy: .public)")
        return choice
    }

    /// The kind of microphone a device is.
    private static func kind(of deviceID: AudioDeviceID) -> AudioInputDevice.Kind {
        if isBuiltInMicrophone(deviceID) { return .builtIn }
        return isSlowToStart(deviceID) ? .slowToStart : .other
    }

    /// Whether a device is the Mac's own microphone.
    ///
    /// Built-in transport alone does not say so: a headset in the headphone jack is
    /// built in too, as "External Microphone". The Mac's own microphone is the one whose
    /// input source is the internal microphone, 'imic' in IOAudioTypes.h, as "MacBook
    /// Pro Microphone" reported on 2026-11-08. A headset's source could not be read
    /// then, with nothing in the jack.
    static func isBuiltInMicrophone(_ deviceID: AudioDeviceID) -> Bool {
        let internalMicrophone: UInt32 = 0x696D_6963  // 'imic'
        return value(kAudioDevicePropertyTransportType, of: deviceID, startingFrom: UInt32(0)) == kAudioDeviceTransportTypeBuiltIn
            && value(kAudioDevicePropertyDataSource, of: deviceID, scope: kAudioDevicePropertyScopeInput,
                     startingFrom: UInt32(0)) == internalMicrophone
    }

    /// The name of the system's default input, which records when no microphone on the
    /// list can hear.
    static func systemDefaultName() -> String {
        guard let deviceID = defaultInputDevice() else { return "System Default" }
        return stringProperty(kAudioObjectPropertyName, for: deviceID) ?? "System Default"
    }

    /// The microphone a recording with this setting uses: the chosen one while it is
    /// connected, and otherwise the system default, which is where the capture falls
    /// back to.
    static func recordingDevice(forUID uid: String) -> AudioDeviceID? {
        if uid != AudioInputDevice.systemDefaultUID, let device = resolveDeviceID(uid: uid) {
            return device
        }
        return defaultInputDevice()
    }

    /// A device's name, as macOS shows it.
    static func name(of deviceID: AudioDeviceID) -> String? {
        stringProperty(kAudioObjectPropertyName, for: deviceID)
    }

    private static func defaultInputDevice() -> AudioDeviceID? {
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID
        )
        return status == noErr && deviceID != kAudioObjectUnknown ? deviceID : nil
    }

    /// Yields whenever a device is added or removed, or the default input changes.
    ///
    /// The listener is a C function with a context pointer, not a block. On this system
    /// the block API does not remove a listener: a removed block keeps firing, even when
    /// the same block constant goes to both calls. The removal still returns noErr. The
    /// same function and context in both calls let the HAL match the removal.
    static func changes() -> AsyncStream<Void> {
        AsyncStream { continuation in
            let token = ChangeSink.register(continuation)
            let system = AudioObjectID(kAudioObjectSystemObject)
            let selectors = [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultInputDevice]

            for selector in selectors {
                var address = AudioObjectPropertyAddress(
                    mSelector: selector,
                    mScope: kAudioObjectPropertyScopeGlobal,
                    mElement: kAudioObjectPropertyElementMain
                )
                AudioObjectAddPropertyListener(system, &address, ChangeSink.proc, ChangeSink.context(token))
            }

            continuation.onTermination = { _ in
                for selector in selectors {
                    var address = AudioObjectPropertyAddress(
                        mSelector: selector,
                        mScope: kAudioObjectPropertyScopeGlobal,
                        mElement: kAudioObjectPropertyElementMain
                    )
                    AudioObjectRemovePropertyListener(system, &address, ChangeSink.proc, ChangeSink.context(token))
                }
                ChangeSink.unregister(token)
            }
        }
    }

    /// Carries each stream's continuation to the listener function, found by a number
    /// in the context pointer rather than by a pointer to an object.
    ///
    /// Removing a listener does not wait for a notification already on its way. The HAL
    /// calls `proc` on its own notification thread, and a call that started before
    /// AudioObjectRemovePropertyListener returned can arrive after it. A context that
    /// pointed at an object, freed with its stream, was then read after it was freed.
    /// A number that is no longer registered finds nothing, and the late call does
    /// nothing. `yield` is thread-safe, and the stream's consumer resumes on its own
    /// actor.
    private enum ChangeSink {
        private static let streams = OSAllocatedUnfairLock(
            initialState: (next: UInt(1), continuations: [UInt: AsyncStream<Void>.Continuation]())
        )

        /// A number for the stream, never zero, so it makes a valid context pointer.
        static func register(_ continuation: AsyncStream<Void>.Continuation) -> UInt {
            streams.withLock { state in
                let token = state.next
                state.next += 1
                state.continuations[token] = continuation
                return token
            }
        }

        /// Called once the stream's listeners are removed.
        static func unregister(_ token: UInt) {
            _ = streams.withLock { $0.continuations.removeValue(forKey: token) }
        }

        static func context(_ token: UInt) -> UnsafeMutableRawPointer? {
            UnsafeMutableRawPointer(bitPattern: token)
        }

        static let proc: AudioObjectPropertyListenerProc = { _, _, _, context in
            let token = UInt(bitPattern: context)
            streams.withLock { $0.continuations[token] }?.yield()
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

    // MARK: - Whether a Microphone Can Hear

    /// Why this microphone cannot hear, or nil when it can: it is present, not muted,
    /// its volume is above zero, and it is not the built-in one behind a closed lid.
    ///
    /// The one test of whether a microphone can hear. A dictation asks it at the start,
    /// so that a microphone that cannot hear is named at once; choosing among several
    /// microphones can ask it to pass over one.
    static func hearingProblem(of deviceID: AudioDeviceID) -> MicrophoneProblem? {
        guard value(kAudioDevicePropertyDeviceIsAlive, of: deviceID, startingFrom: UInt32(0)) == 1 else {
            return .missing
        }
        if isMuted(deviceID) { return .muted }
        if volumeIsOff(deviceID) { return .volumeOff }
        // The Mac's own microphone only. A headset in the headphone jack is built in
        // too, and it hears with the lid closed; tested by transport, it would be
        // warned about as "The lid is closed" through every dictation in clamshell mode.
        if isBuiltInMicrophone(deviceID), lidIsClosed() {
            return .lidClosed
        }
        return nil
    }

    /// Whether a microphone takes seconds to start: Bluetooth, and an iPhone's through
    /// Continuity.
    static func isSlowToStart(_ deviceID: AudioDeviceID) -> Bool {
        let slow = [
            kAudioDeviceTransportTypeBluetooth,
            kAudioDeviceTransportTypeBluetoothLE,
            kAudioDeviceTransportTypeContinuityCaptureWired,
            kAudioDeviceTransportTypeContinuityCaptureWireless
        ]
        return value(kAudioDevicePropertyTransportType, of: deviceID, startingFrom: UInt32(0)).map(slow.contains) ?? false
    }

    /// Yields whenever the microphone is muted or unmuted, or its input volume changes.
    ///
    /// Two causes have no listener here. A microphone unplugged mid-dictation ends the
    /// capture, which ends the dictation. A lid closed mid-dictation silences the
    /// built-in microphone, the silence is noticed within a second, and the test above
    /// is asked again then to name the cause.
    static func hearingChanges(of deviceID: AudioDeviceID) -> AsyncStream<Void> {
        AsyncStream { continuation in
            let token = ChangeSink.register(continuation)

            var found: [AudioObjectPropertyAddress] = []
            for element in 0...AudioObjectPropertyElement(inputChannelCount(deviceID)) {
                for selector in [kAudioDevicePropertyMute, kAudioDevicePropertyVolumeScalar] {
                    var address = AudioObjectPropertyAddress(
                        mSelector: selector,
                        mScope: kAudioDevicePropertyScopeInput,
                        mElement: element
                    )
                    if AudioObjectHasProperty(deviceID, &address) { found.append(address) }
                }
            }
            let addresses = found
            for var address in addresses {
                AudioObjectAddPropertyListener(deviceID, &address, ChangeSink.proc, ChangeSink.context(token))
            }

            continuation.onTermination = { _ in
                for var address in addresses {
                    AudioObjectRemovePropertyListener(deviceID, &address, ChangeSink.proc, ChangeSink.context(token))
                }
                ChangeSink.unregister(token)
            }
        }
    }

    /// Muted by its main control, or on every channel of a device that mutes its
    /// channels one by one.
    private static func isMuted(_ deviceID: AudioDeviceID) -> Bool {
        let mutes = inputControls(kAudioDevicePropertyMute, of: deviceID, startingFrom: UInt32(0))
        if let main = mutes[kAudioObjectPropertyElementMain] { return main != 0 }
        return !mutes.isEmpty && mutes.values.allSatisfy { $0 != 0 }
    }

    /// At zero, on a device whose own scale puts zero at silence.
    ///
    /// The built-in microphone's input volume runs from −12 to +12 dB, so at zero it
    /// still hears, 12 dB down (read on 2026-11-08). Zero counts only where the device
    /// gives it no gain at all, or a gain of minus infinity.
    private static func volumeIsOff(_ deviceID: AudioDeviceID) -> Bool {
        var volumes = inputControls(kAudioDevicePropertyVolumeScalar, of: deviceID, startingFrom: Float32(0))
        if let main = volumes[kAudioObjectPropertyElementMain] {
            volumes = [kAudioObjectPropertyElementMain: main]
        }
        return !volumes.isEmpty && volumes.allSatisfy { element, volume in
            // Asked by handing over the volume, here zero, and reading back decibels.
            let decibels = value(kAudioDevicePropertyVolumeScalarToDecibels, of: deviceID,
                                 scope: kAudioDevicePropertyScopeInput, element: element, startingFrom: Float32(0))
            return volume == 0 && (decibels.map { $0 == -.infinity } ?? true)
        }
    }

    /// An input control's value on the main element and on each channel that has one.
    private static func inputControls<Value: BitwiseCopyable>(
        _ selector: AudioObjectPropertySelector,
        of deviceID: AudioDeviceID,
        startingFrom initial: Value
    ) -> [AudioObjectPropertyElement: Value] {
        var values: [AudioObjectPropertyElement: Value] = [:]
        for element in 0...AudioObjectPropertyElement(inputChannelCount(deviceID)) {
            values[element] = value(selector, of: deviceID, scope: kAudioDevicePropertyScopeInput,
                                    element: element, startingFrom: initial)
        }
        return values
    }

    /// Whether the lid is closed, by the power manager's record of it. False on a Mac
    /// without one.
    private static func lidIsClosed() -> Bool {
        let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard root != IO_OBJECT_NULL else { return false }
        defer { IOObjectRelease(root) }
        let state = IORegistryEntryCreateCFProperty(root, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)
        return (state?.takeRetainedValue() as? Bool) ?? false
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
    /// Whether a device is virtual, such as one an app installs to share its sound.
    static func isVirtual(_ deviceID: AudioDeviceID) -> Bool {
        value(kAudioDevicePropertyTransportType, of: deviceID, startingFrom: UInt32(0)) == kAudioDeviceTransportTypeVirtual
    }

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
        inputChannelCount(deviceID) > 0
    }

    private static func inputChannelCount(_ deviceID: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &dataSize) == noErr,
              dataSize > 0 else { return 0 }

        let bufferList = UnsafeMutableRawPointer.allocate(
            byteCount: Int(dataSize),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { bufferList.deallocate() }

        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, bufferList) == noErr else {
            return 0
        }

        let list = UnsafeMutableAudioBufferListPointer(
            bufferList.assumingMemoryBound(to: AudioBufferList.self)
        )
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    /// A property's value, or nil when the device does not have it.
    private static func value<Value: BitwiseCopyable>(
        _ selector: AudioObjectPropertySelector,
        of deviceID: AudioDeviceID,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain,
        startingFrom initial: Value
    ) -> Value? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
        var value = initial
        var size = UInt32(MemoryLayout<Value>.size)
        return AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value) == noErr ? value : nil
    }

    static func stringProperty(
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
