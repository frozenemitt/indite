import Foundation
import os

#if os(macOS)
import CoreAudio

/// Turns the Mac's sound off while a dictation records, and back on when it ends.
///
/// The default output device is muted where it has a mute switch, and turned down to
/// nothing where it has only a volume. A device that is silent already is left alone, so
/// the end of a dictation never switches on a sound the user had switched off.
///
/// What was changed is saved before the change is made, and deleted once it has been
/// undone. A crash or a force quit in between leaves it saved, and the next launch puts
/// the sound back from it: a Mac left silent by an app that is no longer running has
/// nothing on screen to explain it.
///
/// A device that is not connected when its sound is due back keeps its record, and gets
/// its sound back at the next restore that finds it: the end of the next dictation, or
/// the next launch. Deleting the record then left AirPods put away mid-dictation muted
/// for good, since Core Audio reapplies a device's last mute when it reconnects.
enum OutputMute {

    /// What was changed, and on which device: enough to undo it after a relaunch.
    private struct Change: Codable {
        /// The device's UID. Its numeric ID can change when it reconnects.
        let deviceUID: String

        /// For a device with no mute switch, the volume each of its controls had before
        /// it was turned down, by element. Nil when the device was muted.
        let volumes: [AudioObjectPropertyElement: Float32]?

        /// When the change was made.
        let madeAt: Date
    }

    /// The changes not yet undone, by device UID.
    private static let defaultsKey = "outputMuteChanges"

    /// Silence the default output device, unless it is silent already.
    static func mute() {
        guard let device = defaultOutputDevice(),
              let uid = AudioDeviceCatalog.stringProperty(kAudioDevicePropertyDeviceUID, for: device) else { return }
        let name = AudioDeviceCatalog.stringProperty(kAudioObjectPropertyName, for: device) ?? uid
        guard let change = plannedChange(for: device, uid: uid, name: name) else { return }

        // Saved first, so there is no moment when the Mac is silent and nothing on disk
        // says why.
        var changes = savedChanges()
        changes[uid] = change
        save(changes)

        if let volumes = change.volumes {
            Log.audio.notice("Turning \(name, privacy: .public) down for the dictation")
            for element in volumes.keys {
                write(Float32(0), kAudioDevicePropertyVolumeScalar, to: device, element: element, name: name)
            }
        } else {
            Log.audio.notice("Muting \(name, privacy: .public) for the dictation")
            write(UInt32(1), kAudioDevicePropertyMute, to: device, element: kAudioObjectPropertyElementMain, name: name)
        }
    }

    /// Undo what `mute()` changed, on every device that is connected.
    ///
    /// - Parameter maxAge: Undo only changes made this recently, and forget older ones.
    ///   At launch the sound may have been muted on purpose since Indite stopped, and an
    ///   hour-old change is more likely put right by hand than still waiting.
    static func restore(madeWithin maxAge: TimeInterval? = nil) {
        var changes = savedChanges()
        guard !changes.isEmpty else { return }

        for (uid, change) in changes {
            if let maxAge, Date.now.timeIntervalSince(change.madeAt) > maxAge {
                Log.audio.notice("A dictation's mute is more than an hour old, so the sound is left as it is now")
                changes[uid] = nil
                continue
            }
            guard let device = AudioDeviceCatalog.resolveDeviceID(uid: uid) else {
                Log.audio.notice("The device a dictation muted is not connected; its sound goes back when it is")
                continue
            }
            let name = AudioDeviceCatalog.stringProperty(kAudioObjectPropertyName, for: device) ?? uid
            Log.audio.notice("Putting back the sound of \(name, privacy: .public)")

            if let volumes = change.volumes {
                // A control the user has turned up since is left where they put it.
                for (element, volume) in volumes
                where read(kAudioDevicePropertyVolumeScalar, of: device, element: element, as: Float32(0)) == 0 {
                    write(volume, kAudioDevicePropertyVolumeScalar, to: device, element: element, name: name)
                }
            } else {
                write(UInt32(0), kAudioDevicePropertyMute, to: device, element: kAudioObjectPropertyElementMain, name: name)
            }
            changes[uid] = nil
        }
        save(changes)
    }

    private static func savedChanges() -> [String: Change] {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let changes = try? JSONDecoder().decode([String: Change].self, from: data) else { return [:] }
        return changes
    }

    private static func save(_ changes: [String: Change]) {
        if changes.isEmpty {
            UserDefaults.standard.removeObject(forKey: defaultsKey)
        } else {
            UserDefaults.standard.set(try? JSONEncoder().encode(changes), forKey: defaultsKey)
        }
    }

    /// What `mute()` would change on this device, or nil when it should change nothing:
    /// the device is silent already, or has no control that could silence it.
    private static func plannedChange(for device: AudioDeviceID, uid: String, name: String) -> Change? {
        let main = kAudioObjectPropertyElementMain

        if isSettable(kAudioDevicePropertyMute, of: device, element: main) {
            guard read(kAudioDevicePropertyMute, of: device, element: main, as: UInt32(0)) == 0 else {
                Log.audio.notice("\(name, privacy: .public) was muted already, so the dictation leaves it alone")
                return nil
            }
            return Change(deviceUID: uid, volumes: nil, madeAt: .now)
        }

        let volumes = volumeControls(of: device)
        guard !volumes.isEmpty else {
            Log.audio.notice("\(name, privacy: .public) has no mute switch or volume, so its sound stays on")
            return nil
        }
        guard volumes.values.contains(where: { $0 > 0 }) else {
            Log.audio.notice("\(name, privacy: .public) was turned down already, so the dictation leaves it alone")
            return nil
        }
        return Change(deviceUID: uid, volumes: volumes, madeAt: .now)
    }

    /// The device's volume controls that can be set, with their values: the main one,
    /// and one for each channel on a device that has them instead or as well.
    private static func volumeControls(of device: AudioDeviceID) -> [AudioObjectPropertyElement: Float32] {
        func volume(_ element: AudioObjectPropertyElement) -> Float32? {
            guard isSettable(kAudioDevicePropertyVolumeScalar, of: device, element: element) else { return nil }
            return read(kAudioDevicePropertyVolumeScalar, of: device, element: element, as: Float32(0))
        }

        var volumes: [AudioObjectPropertyElement: Float32] = [:]
        volumes[kAudioObjectPropertyElementMain] = volume(kAudioObjectPropertyElementMain)
        var channel: AudioObjectPropertyElement = 1
        while let level = volume(channel) {
            volumes[channel] = level
            channel += 1
        }
        return volumes
    }

    // MARK: - CoreAudio Plumbing

    private static func defaultOutputDevice() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var device = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device
        )
        return status == noErr && device != kAudioObjectUnknown ? device : nil
    }

    private static func outputAddress(
        _ selector: AudioObjectPropertySelector,
        _ element: AudioObjectPropertyElement
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeOutput, mElement: element)
    }

    private static func isSettable(
        _ selector: AudioObjectPropertySelector,
        of device: AudioDeviceID,
        element: AudioObjectPropertyElement
    ) -> Bool {
        var address = outputAddress(selector, element)
        var settable: DarwinBoolean = false
        return AudioObjectHasProperty(device, &address)
            && AudioObjectIsPropertySettable(device, &address, &settable) == noErr
            && settable.boolValue
    }

    private static func read<Value: BitwiseCopyable>(
        _ selector: AudioObjectPropertySelector,
        of device: AudioDeviceID,
        element: AudioObjectPropertyElement,
        as initial: Value
    ) -> Value? {
        var address = outputAddress(selector, element)
        var value = initial
        var size = UInt32(MemoryLayout<Value>.size)
        let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value)
        return status == noErr ? value : nil
    }

    private static func write<Value: BitwiseCopyable>(
        _ value: Value,
        _ selector: AudioObjectPropertySelector,
        to device: AudioDeviceID,
        element: AudioObjectPropertyElement,
        name: String
    ) {
        var address = outputAddress(selector, element)
        var value = value
        let status = AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<Value>.size), &value)
        if status != noErr {
            Log.audio.error("Could not set the sound of \(name, privacy: .public), OSStatus \(status, privacy: .public)")
        }
    }
}
#endif
