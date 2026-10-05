import AppKit
import Foundation
import Observation
import Sparkle
import SwiftUI

/// Draws every step of an update in Nscribe's own Software Update window, in place of
/// Sparkle's windows.
///
/// Sparkle's windows looked like no other part of the app, offered a second switch
/// for automatic updates beside Nscribe's own, and opened behind the app the person
/// was in. Sparkle still decides what happens; this decides only how it is shown, and
/// passes the person's choice back through the reply Sparkle hands it.
///
/// An update found by the daily check is not put in front of the person: they may be
/// dictating. `AppUpdater` says it is there, in the menu and a notification, and the
/// window opens when they ask for it.
@MainActor
@Observable
final class UpdateDriver: NSObject {
    enum Phase: Equatable {
        case idle
        case checking
        case upToDate
        /// Found, and not yet chosen. `infoURL` is set for an update that can only be
        /// read about, not installed.
        case available(version: String, notes: String, infoURL: URL?)
        case downloading(version: String, received: UInt64, expected: UInt64)
        case preparing(version: String)
        case ready(version: String)
        case installing(version: String)
        case failed(title: String, message: String)
    }

    private(set) var phase = Phase.idle

    /// The version on offer from a check the person did not start, while they have not
    /// looked at it.
    private(set) var waitingVersion: String?

    /// Told when an update found by the daily check is waiting for the person.
    @ObservationIgnored var onUpdateWaiting: ((String) -> Void)?

    @ObservationIgnored private let window = HostedWindow()
    @ObservationIgnored private var choiceReply: ((SPUUserUpdateChoice) -> Void)?
    @ObservationIgnored private var cancellation: (() -> Void)?
    @ObservationIgnored private var acknowledgement: (() -> Void)?

    override init() {
        super.init()
        window.onClose = { [weak self] in self?.closedByPerson() }
    }

    /// The version this copy of Nscribe is.
    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }

    // MARK: - The person's choices

    func installNow() { reply(.install) }
    func notNow() { reply(.dismiss) }

    func cancel() {
        let cancellation = self.cancellation
        self.cancellation = nil
        cancellation?()
        finish()
    }

    func acknowledge() {
        let acknowledgement = self.acknowledgement
        self.acknowledgement = nil
        acknowledgement?()
        finish()
    }

    func openInfoPage(_ url: URL) {
        NSWorkspace.shared.open(url)
        reply(.dismiss)
    }

    /// Show the window for what is under way, if anything is.
    func present() {
        guard phase != .idle else { return }
        waitingVersion = nil
        window.show(title: "Software Update") { SoftwareUpdateView(driver: self) }
    }

    // MARK: - Internals

    private func reply(_ choice: SPUUserUpdateChoice) {
        let reply = choiceReply
        choiceReply = nil
        reply?(choice)
        if choice != .install { finish() }
    }

    private func finish() {
        phase = .idle
        waitingVersion = nil
        window.close()
    }

    /// The close button answers as the gentlest button in the window would.
    private func closedByPerson() {
        switch phase {
        case .checking, .downloading: cancel()
        case .available, .ready: notNow()
        case .upToDate, .failed: acknowledge()
        case .idle, .preparing, .installing: break
        }
    }

    private var currentlyOfferedVersion: String {
        switch phase {
        case .available(let version, _, _), .downloading(let version, _, _),
             .preparing(let version), .ready(let version), .installing(let version):
            version
        default:
            "the update"
        }
    }
}

extension UpdateDriver: SPUUserDriver {
    /// Never asked: Info.plist turns automatic updates on, and the welcome window and
    /// Settings carry the switch.
    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: true, sendSystemProfile: false))
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        self.cancellation = cancellation
        phase = .checking
        present()
    }

    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        cancellation = nil
        choiceReply = reply
        let infoURL = appcastItem.isInformationOnlyUpdate ? appcastItem.infoURL : nil
        phase = .available(version: appcastItem.displayVersionString,
                           notes: appcastItem.itemDescription ?? "",
                           infoURL: infoURL)
        if state.userInitiated || window.isVisible {
            present()
        } else {
            waitingVersion = appcastItem.displayVersionString
            onUpdateWaiting?(appcastItem.displayVersionString)
        }
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {
        guard case .available(let version, _, let infoURL) = phase,
              let notes = String(data: downloadData.data, encoding: .utf8) else { return }
        phase = .available(version: version, notes: notes, infoURL: infoURL)
    }

    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: any Error) {}

    func showUpdateNotFoundWithError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        cancellation = nil
        self.acknowledgement = acknowledgement
        let reason = (error as NSError).userInfo[SPUNoUpdateFoundReasonKey] as? Int
        if reason == nil || reason == Int(SPUNoUpdateFoundReason.onLatestVersion.rawValue)
            || reason == Int(SPUNoUpdateFoundReason.onNewerThanLatestVersion.rawValue) {
            phase = .upToDate
        } else {
            phase = .failed(title: "No update for this Mac", message: Self.explain(error))
        }
        present()
    }

    func showUpdaterError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        cancellation = nil
        choiceReply = nil
        self.acknowledgement = acknowledgement
        let checking = phase == .checking || phase == .idle
        phase = .failed(title: checking ? "Couldn’t check for updates" : "Couldn’t install the update",
                        message: Self.explain(error))
        present()
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        self.cancellation = cancellation
        phase = .downloading(version: currentlyOfferedVersion, received: 0, expected: 0)
    }

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        guard case .downloading(let version, let received, _) = phase else { return }
        phase = .downloading(version: version, received: received, expected: expectedContentLength)
    }

    func showDownloadDidReceiveData(ofLength length: UInt64) {
        guard case .downloading(let version, let received, let expected) = phase else { return }
        phase = .downloading(version: version, received: received + length, expected: expected)
    }

    func showDownloadDidStartExtractingUpdate() {
        cancellation = nil
        phase = .preparing(version: currentlyOfferedVersion)
    }

    func showExtractionReceivedProgress(_ progress: Double) {}

    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        choiceReply = reply
        phase = .ready(version: currentlyOfferedVersion)
        present()
    }

    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void) {
        phase = .installing(version: currentlyOfferedVersion)
    }

    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        acknowledgement()
    }

    func dismissUpdateInstallation() {
        choiceReply = nil
        cancellation = nil
        acknowledgement = nil
        finish()
    }

    func showUpdateInFocus() {
        present()
    }

    /// Sparkle's message, with its suggestion when it has one.
    private static func explain(_ error: any Error) -> String {
        let error = error as NSError
        return [error.localizedDescription, error.localizedRecoverySuggestion]
            .compactMap { $0 }
            .joined(separator: " ")
    }
}
