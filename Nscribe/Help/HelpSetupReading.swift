#if os(macOS)
import AVFoundation
import Speech

extension HelpSetup {
    /// The setup as it is this moment, read the way Settings' Status list reads it.
    ///
    /// The dictation key's setting is read from a fresh `AppSettings`, as the App
    /// Intents read settings, so Help needs no handle on the app's own instance.
    @MainActor
    static func current() -> HelpSetup {
        let settings = AppSettings()
        let hotkey = GlobalHotkeyMonitor.shared

        func permission(_ status: AVAuthorizationStatus) -> Permission {
            switch status {
            case .authorized: .allowed
            case .denied, .restricted: .refused
            default: .notAsked
            }
        }
        let speech: Permission = switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: .allowed
        case .denied, .restricted: .refused
        default: .notAsked
        }

        return HelpSetup(
            accessibility: AccessibilityPermission.isTrusted,
            keyError: hotkey.hasFailed ? hotkey.lastError : nil,
            usesGlobeKey: settings.useGlobeKey,
            globeKeyDoesNothing: GlobalHotkeyMonitor.globeKeyDoesNothing,
            microphone: permission(AVCaptureDevice.authorizationStatus(for: .audio)),
            speech: speech,
            appleIntelligence: AIProcessor.unavailabilityReason,
            speakerModels: DiarizationModelStore.isInstalled,
            meetingsNotSaved: MeetingStoreStatus.shared.isPersistent
                ? nil : (MeetingStoreStatus.shared.failureReason ?? "The store could not be opened.")
        )
    }
}
#endif
