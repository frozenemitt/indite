import Foundation

/// One page of Indite's documentation: one task or one question.
///
/// The articles are the single source for help. The Help window shows them, and they
/// are indexed into Spotlight as `HelpArticleEntity`, which is how Siri finds them and
/// answers from them. See `Docs/help-and-siri.md`.
struct HelpArticle: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let body: String
    let topic: Topic
    /// The one thing to do about it, offered as a button under an answer drawn from
    /// this article.
    var action: Action? = nil

    /// Where an article sits when the articles are browsed, in this order.
    enum Topic: String, CaseIterable, Hashable, Sendable {
        case gettingStarted = "Getting Started"
        case dictation = "Dictation"
        case rewriting = "Rewriting"
        case words = "Words and Spelling"
        case meetings = "Meetings"
        case siri = "Siri and Shortcuts"
        case privacy = "Privacy and Permissions"
        case troubleshooting = "Troubleshooting"
    }

    enum Action: Hashable, Sendable {
        /// Indite's Settings, at the tab the article names.
        case inditeSettings(SettingsTab)
        case keyboardSettings
        case screenRecordingSettings
        case accessibilitySettings
        case microphoneSettings
        case speechSettings

        var title: String {
            switch self {
            case .inditeSettings: "Open Indite Settings"
            case .keyboardSettings: "Open Keyboard Settings"
            case .screenRecordingSettings: "Open Screen & System Audio Recording"
            case .accessibilitySettings: "Open Accessibility Settings"
            case .microphoneSettings: "Open Microphone Settings"
            case .speechSettings: "Open Speech Recognition Settings"
            }
        }
    }
}

extension HelpArticle {
    /// Every article, in the order the topics list them. The articles themselves are in
    /// `HelpLibrary.swift`.
    static let all: [HelpArticle] = HelpLibrary.articles

    static func article(id: String) -> HelpArticle? {
        all.first { $0.id == id }
    }
}
