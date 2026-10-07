import Foundation
import UniformTypeIdentifiers

#if os(macOS)
import AppKit
#endif

/// Discovers available system sounds and manages custom imported sounds
@MainActor
@Observable
final class SoundCatalog {

    // MARK: - Constants

    /// Sentinel value representing silence (no sound)
    static let noneID = "none"

    /// Prefix for custom sound identifiers
    static let customPrefix = "custom:"

    // MARK: - Sound Item

    struct SoundItem: Identifiable, Hashable {
        let id: String
        let displayName: String
    }

    // MARK: - State

    private(set) var systemSounds: [SoundItem] = []
    private(set) var customSounds: [SoundItem] = []

    #if os(macOS)
    private var previewingSound: NSSound?
    #endif

    /// All available sounds: None + system + custom
    var allSounds: [SoundItem] {
        [SoundItem(id: Self.noneID, displayName: "None")]
        + systemSounds
        + customSounds
    }

    // MARK: - Singleton

    static let shared = SoundCatalog()

    private init() {
        loadSystemSounds()
        loadCustomSounds()
    }

    // MARK: - System Sounds Discovery

    #if os(macOS)
    private func loadSystemSounds() {
        let path = "/System/Library/Sounds"
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: path) else { return }

        systemSounds = files
            .filter { $0.hasSuffix(".aiff") }
            .map { filename in
                let name = (filename as NSString).deletingPathExtension
                return SoundItem(id: name, displayName: name)
            }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }
    #else
    private func loadSystemSounds() {
        // iOS doesn't support named system sounds
    }
    #endif

    // MARK: - Custom Sounds

    private var customSoundsDirectory: URL {
        AppFolder.url.appendingPathComponent("Sounds", isDirectory: true)
    }

    private func loadCustomSounds() {
        let dir = customSoundsDirectory
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: nil
        ) else { return }

        // Any audio type counts, as it does in the import panel. NSSound plays AIF, CAF,
        // AAC and FLAC files alike, and a fixed list of extensions here copied such files
        // in but hid them from every picker and from the delete button.
        customSounds = files
            .filter { UTType(filenameExtension: $0.pathExtension)?.conforms(to: .audio) == true }
            .map { url in
                SoundItem(
                    id: "\(Self.customPrefix)\(url.lastPathComponent)",
                    displayName: url.deletingPathExtension().lastPathComponent
                )
            }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    /// Import a sound file into the custom sounds directory
    func importSound(from sourceURL: URL) throws {
        let dir = customSoundsDirectory
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // Copy into a temporary directory on the same volume and swap the copy in, rather
        // than deleting the old file first. Deleting first lost the existing sound whenever
        // the copy failed, and re-importing a file picked from the Sounds folder itself
        // deleted the only copy before reading it. replaceItemAt also accepts a
        // destination that does not exist yet.
        let destination = dir.appendingPathComponent(sourceURL.lastPathComponent)
        let staging = try FileManager.default.url(
            for: .itemReplacementDirectory,
            in: .userDomainMask,
            appropriateFor: destination,
            create: true
        )
        defer { try? FileManager.default.removeItem(at: staging) }

        let staged = staging.appendingPathComponent(sourceURL.lastPathComponent)
        try FileManager.default.copyItem(at: sourceURL, to: staged)
        _ = try FileManager.default.replaceItemAt(destination, withItemAt: staged)
        loadCustomSounds()
    }

    /// Delete a custom sound by its identifier
    func deleteCustomSound(id: String) throws {
        guard id.hasPrefix(Self.customPrefix) else { return }
        let filename = String(id.dropFirst(Self.customPrefix.count))
        let url = customSoundsDirectory.appendingPathComponent(filename)
        try FileManager.default.removeItem(at: url)
        loadCustomSounds()
    }

    // MARK: - Playback

    #if os(macOS)
    /// Preview a sound (stops any currently previewing sound first)
    func preview(_ soundId: String) {
        previewingSound?.stop()
        previewingSound = nil

        guard soundId != Self.noneID else { return }
        let sound = makeNSSound(for: soundId)
        sound?.play()
        previewingSound = sound
    }

    /// Create a new NSSound instance for the given sound identifier
    func makeNSSound(for soundId: String) -> NSSound? {
        guard soundId != Self.noneID else { return nil }

        if soundId.hasPrefix(Self.customPrefix) {
            let filename = String(soundId.dropFirst(Self.customPrefix.count))
            let url = customSoundsDirectory.appendingPathComponent(filename)
            return NSSound(contentsOf: url, byReference: true)
        } else {
            // NSSound(named:) returns one cached instance per name, and play() on an
            // instance that is still playing returns false and stays silent. A copy per
            // call lets two events share a sound, such as Stop and Complete both set to
            // Glass, and keeps the processing loop's loops flag off every other play. The
            // copy measured 0.03 ms warm and 0.17 ms the first time.
            return NSSound(named: soundId)?.copy() as? NSSound
        }
    }
    #endif
}
