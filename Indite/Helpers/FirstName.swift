import Foundation
import os

/// What carries over from the app's first name, Nscribe.
///
/// Nscribe had its own bundle identifier, and macOS keeps an app's settings under its
/// identifier, so Indite starts with none of them. The first launch copies them
/// across. Meetings and recordings move with the app's folder, in `AppFolder`.
enum FirstName {
    static let bundleIdentifier = "com.nscribe.app.macos"

    /// Copies, once, each of Nscribe's settings that Indite does not have yet.
    static func carrySettingsOver() {
        let defaults = UserDefaults.standard
        let done = "SettingsCarriedOverFromNscribe"
        guard !defaults.bool(forKey: done), let own = Bundle.main.bundleIdentifier else { return }
        defer { defaults.set(true, forKey: done) }

        guard let first = defaults.persistentDomain(forName: bundleIdentifier), !first.isEmpty else { return }
        let current = defaults.persistentDomain(forName: own) ?? [:]
        let missing = first.filter { current[$0.key] == nil }
        for (key, value) in missing {
            defaults.set(value, forKey: key)
        }
        Log.settings.notice("Carried \(missing.count, privacy: .public) settings over from Nscribe")
    }
}
