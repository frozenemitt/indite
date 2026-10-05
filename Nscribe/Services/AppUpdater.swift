import AppKit
import Foundation
import Observation
import Sparkle
import SwiftUI
import os
import UserNotifications

/// Finds a newer Nscribe on GitHub, downloads it, and asks for a restart to install it,
/// through Sparkle. Every step is drawn by `UpdateDriver` in Nscribe's own windows.
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

    /// Draws the updates; also holds an update the daily check found and could not
    /// download by itself, until the person looks at it.
    let driver = UpdateDriver()

    /// The notes for What's New, on the first launch of a new version.
    private(set) var whatsNew: WhatsNew?

    struct WhatsNew: Equatable {
        let version: String
        let notes: String
    }

    @ObservationIgnored private var updater: SPUUpdater!
    @ObservationIgnored private var canCheckObservation: NSKeyValueObservation?
    @ObservationIgnored private var installReadyUpdate: (() -> Void)?

    /// Marks the notifications this class posts, so a click on one restarts the app
    /// and a click on a dictation's notification does not.
    nonisolated private static let notificationCategory = "update"

    private override init() {
        super.init()
        let updater = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: driver, delegate: self)
        self.updater = updater
        do {
            try updater.start()
        } catch {
            Log.app.error("The updater would not start: \(error, privacy: .public)")
        }
        driver.onUpdateWaiting = { [weak self] version in
            self?.notify(title: "Nscribe \(version) is available",
                         body: "Click to see what’s new and install it.")
        }
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
        updater.automaticallyChecksForUpdates = on
        updater.automaticallyDownloadsUpdates = on
    }

    /// Check now, and show the result whatever it is, "You're up to date" included.
    func checkForUpdates() {
        if driver.waitingVersion != nil {
            driver.present()
        } else {
            updater.checkForUpdates()
        }
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
        // The notification and the menu line come here for an update still waiting to
        // be looked at, too: `checkForUpdates` opens it.
    }

    // MARK: - What's New

    private static let whatsNewKey = "whatsNew"

    /// Open What's New if this is the first launch of a version Sparkle installed.
    func showWhatsNewIfDue() {
        guard let saved = UserDefaults.standard.dictionary(forKey: Self.whatsNewKey) as? [String: String],
              saved["version"] == UpdateDriver.currentVersion else { return }
        UserDefaults.standard.removeObject(forKey: Self.whatsNewKey)
        let notes = saved["notes"] ?? ""
        guard !notes.isEmpty else { return }
        whatsNew = WhatsNew(version: UpdateDriver.currentVersion, notes: notes)
        FamilyWindows.show(FamilyWindows.whatsNew)
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

    /// Kept for What's New, which opens on the new version's first launch. Called on
    /// every way an update gets installed.
    func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
        UserDefaults.standard.set(["version": item.displayVersionString, "notes": item.itemDescription ?? ""],
                                  forKey: Self.whatsNewKey)
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
