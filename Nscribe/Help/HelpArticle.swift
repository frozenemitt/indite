import Foundation

/// One page of Nscribe's documentation: one task or one question.
///
/// The articles are the single source for help. The Help window shows them, and they
/// are indexed into Spotlight as `HelpArticleEntity`, which is how Siri finds them and
/// answers from them. See `Docs/help-and-siri.md`.
struct HelpArticle: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let body: String
    /// The one thing to do about it, offered as a button under an answer drawn from
    /// this article.
    var action: Action? = nil

    enum Action: Hashable, Sendable {
        case nscribeSettings
        case keyboardSettings
        case screenRecordingSettings

        var title: String {
            switch self {
            case .nscribeSettings: "Open Nscribe Settings"
            case .keyboardSettings: "Open Keyboard Settings"
            case .screenRecordingSettings: "Open Screen & System Audio Recording"
            }
        }
    }
}

extension HelpArticle {
    static let all: [HelpArticle] = [dictationKey, globeKeyEmoji, callAudio]

    static func article(id: String) -> HelpArticle? {
        all.first { $0.id == id }
    }

    static let dictationKey = HelpArticle(
        id: "dictation-key",
        title: "Change the dictation key",
        body: """
            Nscribe starts dictating when you press the Globe key (🌐), unless you choose \
            another key.

            To use a key combination instead, open Nscribe's Settings, choose Dictation, \
            turn off "Use the Globe key", and record the combination you want.

            Under "Pressing it", choose "Hold to talk" to dictate only while the key is \
            held down, or "Press to start, press to stop" to keep dictating until you \
            press it again. Escape discards a dictation in progress.
            """,
        action: .nscribeSettings
    )

    static let globeKeyEmoji = HelpArticle(
        id: "globe-key-emoji",
        title: "The Globe key opens the emoji picker",
        body: """
            macOS uses the Globe key (🌐) too. If pressing it opens the emoji picker or \
            switches your keyboard, open System Settings, choose Keyboard, and set \
            "Press 🌐 key to" to Do Nothing. The "Open Keyboard Settings" link in \
            Nscribe's Dictation settings goes straight there.

            The emoji picker is still on Control-Command-Space (⌃⌘Space), Apple's own \
            default.
            """,
        action: .keyboardSettings
    )

    static let callAudio = HelpArticle(
        id: "call-audio",
        title: "Record both sides of a call",
        body: """
            A meeting records your microphone. To record the other people on a call as \
            well, open Nscribe's Settings, choose Meetings, and turn on "Record system \
            audio, for the other side of a call". Then click "Allow Nscribe in Screen & \
            System Audio Recording…" and turn Nscribe on in the list macOS shows. \
            Nscribe takes only the sound.

            This works with any app that plays the call through your Mac. It records \
            everyone audible on the call, so check that the people you are meeting with \
            are content to be recorded.
            """,
        action: .screenRecordingSettings
    )
}
