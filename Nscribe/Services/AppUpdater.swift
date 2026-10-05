import AppKit
import Foundation
import Observation
import Sparkle
import UserNotifications

/// Finds a newer Nscribe on GitHub, downloads it, and asks for a restart to install it,
/// through Sparkle.
///
/// Every GitHub release carries an appcast, a small XML file that names the newest
/// build and the EdDSA signature of its disk image. `SUFeedURL` in Info.plist points
/// at the latest release's copy, so publishing a release is what offers it to
/// everyone. Sparkle checks the signature against `SUPublicEDKey` before it installs
/// anything, and an update installed from inside the app is never marked as
/// downloaded, so macOS does not ask the user to approve it a second time.
///
/// With updates on, which Info.plist makes the default, Sparkle checks once a day and
/// downloads what it finds. It would then wait for the app to quit, and Nscribe is
/// left running for weeks, so the user is told and offered a restart instead: a
/// notification, and a line at the top of the menu until they take it. The check is
/// the only network call Nscribe makes without being asked, and it carries nothing
/// about the Mac: Sparkle's system profile stays off.
@MainActor
@Observable
final class AppUpdater: NSObject {
    static let shared = AppUpdater()

    /// False while a check is already under way.
    private(set) var canCheckForUpdates = false

    /// One switch for both halves of updating on its own: the daily check, and the
    /// download that makes a restart all that is left to do.
    private(set) var updatesAutomatically = true

    /// The version downloaded and waiting for a restart.
    private(set) var readyVersion: String?

    @ObservationIgnored private var controller: SPUStandardUpdaterController!
    @ObservationIgnored private var canCheckObservation: NSKeyValueObservation?
    @ObservationIgnored private var installReadyUpdate: (() -> Void)?

    /// Marks the notifications this class posts, so a click on one restarts the app
    /// and a click on a dictation's notification does not.
    nonisolated private static let notificationCategory = "update"

    private override init() {
        super.init()
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: self)
        let updater = controller.updater
        updatesAutomatically = updater.automaticallyChecksForUpdates && updater.automaticallyDownloadsUpdates
        UNUserNotificationCenter.current().delegate = self

        // The closure takes the main actor from this class, so it must run on the main
        // thread. Sparkle changes the property only there.
        canCheckObservation = updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
            self?.canCheckForUpdates = updater.canCheckForUpdates
        }
    }

    func setUpdatesAutomatically(_ on: Bool) {
        updatesAutomatically = on
        controller.updater.automaticallyChecksForUpdates = on
        controller.updater.automaticallyDownloadsUpdates = on
    }

    /// Check now, and show the result whatever it is, "You're up to date" included.
    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }

    /// Install the downloaded update and open the new version.
    ///
    /// Quitting goes through the app delegate, so a meeting or dictation still open is
    /// saved first.
    func restartToUpdate() {
        if let installReadyUpdate {
            installReadyUpdate()
        } else {
            checkForUpdates()
        }
    }

    private func notify(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.categoryIdentifier = Self.notificationCategory
        let request = UNNotificationRequest(identifier: Self.notificationCategory, content: content, trigger: nil)

        Task {
            let center = UNUserNotificationCenter.current()
            _ = try? await center.requestAuthorization(options: [.alert])
            try? await center.add(request)
        }
    }
}

extension AppUpdater: SPUUpdaterDelegate {
    /// An update has downloaded and Sparkle would install it at the next quit.
    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem, immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        readyVersion = item.displayVersionString
        installReadyUpdate = immediateInstallHandler
        notify(title: "Nscribe \(item.displayVersionString) is ready",
               body: "Click to restart Nscribe and finish updating.")
        return true
    }
}

extension AppUpdater: SPUStandardUserDriverDelegate {
    /// Sparkle opens the window for an update found by the daily check behind other
    /// apps, since a menu bar app is rarely the one in front. That happens only for an
    /// update it could not download by itself, and the notification says it is there.
    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        guard !state.userInitiated else { return }
        notify(title: "Nscribe \(update.displayVersionString) is available",
               body: "Click to see what is new and install it.")
    }
}

extension AppUpdater: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard response.notification.request.content.categoryIdentifier == Self.notificationCategory else { return }
        await MainActor.run { self.restartToUpdate() }
    }

    /// Shown even while Nscribe is the active app. Its other notifications keep the
    /// system's default, which is to stay quiet then.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        notification.request.content.categoryIdentifier == Self.notificationCategory ? [.banner, .list] : []
    }
}
