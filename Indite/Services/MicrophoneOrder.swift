import Foundation

/// The microphones in the order the user ranks them, and the one a recording takes.
///
/// Jonathan chose a ranked list over the system default on 2026-11-08. macOS moves its
/// default input to AirPods when they connect, and a Bluetooth microphone takes seconds
/// to start and sends phone-call-quality sound while in use; Wispr Flow tells its users
/// that AirPods make more dictation errors, and recommends the Mac's own microphone.
/// The list starts with the built-in microphone, and each recording takes the first
/// microphone on it that can hear right then. A microphone that stops hearing during
/// a recording is warned about, not swapped for the next one.
///
/// Everything here works on lists it is handed, so the choice can be tried on made-up
/// devices. `AudioDeviceCatalog.microphone(for:)` hands it the real ones.
enum MicrophoneOrder {

    /// Which microphone a recording takes, and why the ones above it were passed over.
    struct Choice: Sendable {
        /// The microphone chosen, or nil when none on the list can hear and the
        /// recording follows the system default.
        let microphone: AudioInputDevice?
        /// The microphones ranked above it, each with what stops it hearing.
        let passedOver: [Passed]

        struct Passed: Equatable, Sendable {
            let microphone: AudioInputDevice
            let problem: MicrophoneProblem
        }

        /// The UID to record from: the chosen microphone's, or the system default's.
        var uid: String { microphone?.uid ?? AudioInputDevice.systemDefaultUID }

        /// One line for the log: the microphone, and why each one above it was not taken.
        var summary: String {
            let chosen = microphone.map { "Chose \($0.name)" }
                ?? "No microphone on the list can hear, so the system default records"
            guard !passedOver.isEmpty else { return chosen }
            let passed = passedOver.map { "\($0.microphone.name) (\($0.problem.reason))" }
            return chosen + "; passed over " + passed.joined(separator: ", ")
        }
    }

    /// The first microphone on the list that can hear.
    ///
    /// - Parameters:
    ///   - order: The user's ranked list.
    ///   - connected: The microphones connected now, in the system's order. One the
    ///     list lacks is ranked at the bottom, where the list adds it.
    ///   - problem: Why a connected microphone cannot hear, by UID, or nil when it can.
    static func choose(
        from order: [AudioInputDevice],
        connected: [AudioInputDevice],
        problem: (String) -> MicrophoneProblem?
    ) -> Choice {
        var passedOver: [Choice.Passed] = []
        for microphone in remembering(connected, in: order) {
            let isConnected = connected.contains { $0.uid == microphone.uid }
            guard let found = isConnected ? problem(microphone.uid) : .missing else {
                return Choice(microphone: microphone, passedOver: passedOver)
            }
            passedOver.append(Choice.Passed(microphone: microphone, problem: found))
        }
        return Choice(microphone: nil, passedOver: passedOver)
    }

    /// The list with every connected microphone it lacks added at the bottom, in the
    /// system's order, and the names of the ones it has brought up to date.
    ///
    /// A microphone that is unplugged stays where it was, so it is back in its place
    /// when it returns.
    static func remembering(_ connected: [AudioInputDevice], in order: [AudioInputDevice]) -> [AudioInputDevice] {
        var updated = order.map { listed in connected.first { $0.uid == listed.uid } ?? listed }
        for device in connected where !updated.contains(where: { $0.uid == device.uid }) {
            updated.append(device)
        }
        return updated
    }

    /// Whether a Bluetooth or Continuity microphone is ranked above the Mac's own.
    static func slowMicrophoneLeads(_ order: [AudioInputDevice]) -> Bool {
        guard let builtIn = order.firstIndex(where: { $0.kind == .builtIn }) else { return false }
        return order[..<builtIn].contains { $0.kind == .slowToStart }
    }

    // MARK: - Stored

    /// Where the list is kept: an array of dictionaries, so `defaults read` shows it.
    static let defaultsKey = "microphoneOrder"

    /// The single choice the list replaced: a microphone's UID, or "default" to follow
    /// the system.
    static let replacedKey = "inputDeviceUID"

    /// The stored list, made from the choice it replaced the first time it is read.
    ///
    /// - Parameter connected: The microphones connected now, asked for only when the
    ///   list is made.
    static func stored(in defaults: UserDefaults, connected: @autoclosure () -> [AudioInputDevice]) -> [AudioInputDevice] {
        if let entries = defaults.array(forKey: defaultsKey) as? [[String: String]] {
            return entries.compactMap { entry in
                guard let uid = entry["uid"] else { return nil }
                return AudioInputDevice(uid: uid, name: entry["name"] ?? uid,
                                        kind: entry["kind"].flatMap(AudioInputDevice.Kind.init(rawValue:)) ?? .other)
            }
        }
        let order = movedOver(from: defaults.string(forKey: replacedKey), connected: connected())
        save(order, in: defaults)
        defaults.removeObject(forKey: replacedKey)
        return order
    }

    static func save(_ order: [AudioInputDevice], in defaults: UserDefaults) {
        defaults.set(order.map { ["uid": $0.uid, "name": $0.name, "kind": $0.kind.rawValue] }, forKey: defaultsKey)
    }

    /// The list a stored choice becomes, as Jonathan set out on 2026-11-08.
    ///
    /// Following the system default, or nothing stored, becomes the built-in microphone
    /// first and the others after it in the order the system lists them. A chosen
    /// microphone stays first, with the built-in one after it and the others after
    /// that. One that is not connected keeps its place with its UID for a name, which
    /// is all that was stored, until it appears.
    static func movedOver(from stored: String?, connected: [AudioInputDevice]) -> [AudioInputDevice] {
        var first: [AudioInputDevice] = []
        if let stored, stored != AudioInputDevice.systemDefaultUID {
            first.append(connected.first { $0.uid == stored }
                         ?? AudioInputDevice(uid: stored, name: stored, kind: .other))
        }
        let builtIn = connected.filter { $0.kind == .builtIn }
        return remembering(connected, in: remembering(builtIn, in: first))
    }
}
