import Foundation
import Observation
import Sparkle

/// Finds a newer Nscribe on GitHub and installs it, through Sparkle.
///
/// Every GitHub release carries an appcast, a small XML file that names the newest
/// build and the EdDSA signature of its disk image. `SUFeedURL` in Info.plist points
/// at the latest release's copy, so publishing a release is what offers it to
/// everyone. Sparkle checks the signature against `SUPublicEDKey` before it installs
/// anything, and an update installed from inside the app is never marked as
/// downloaded, so macOS does not ask the user to approve it a second time.
///
/// This is the only network call Nscribe makes without being asked. Sparkle asks on
/// the second launch whether to check automatically, and the request carries nothing
/// about the Mac: Sparkle's system profile stays off.
@MainActor
@Observable
final class AppUpdater {
    static let shared = AppUpdater()

    /// False while a check is already under way.
    private(set) var canCheckForUpdates = false

    /// Mirrors Sparkle's own setting, which it keeps in the app's user defaults.
    var automaticallyChecksForUpdates: Bool {
        didSet { controller.updater.automaticallyChecksForUpdates = automaticallyChecksForUpdates }
    }

    @ObservationIgnored private let controller: SPUStandardUpdaterController
    @ObservationIgnored private var canCheckObservation: NSKeyValueObservation?

    private init() {
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        automaticallyChecksForUpdates = controller.updater.automaticallyChecksForUpdates

        // The closure takes the main actor from this class, so it must run on the main
        // thread. Sparkle changes the property only there.
        canCheckObservation = controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
            self?.canCheckForUpdates = updater.canCheckForUpdates
        }
    }

    /// Check now, and show the result whatever it is, "You're up to date" included.
    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }
}
