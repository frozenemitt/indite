import Foundation

/// What Nscribe can see of its own setup, for Help: the checks Settings' Status list
/// and the welcome window make.
///
/// Read only, and never anything the person said or recorded. Help shows the checks
/// itself: urgent problems on its opening screen, and beside an answer the checks
/// that bear on it, so a person reads "Accessibility is off" rather than "most likely".
struct HelpSetup: Equatable, Sendable {
    enum Permission: Equatable, Sendable { case allowed, refused, notAsked }

    var accessibility: Bool
    /// Why the dictation key is not working although Accessibility is on.
    var keyError: String?
    var usesGlobeKey: Bool
    /// Whether macOS's "Press 🌐 key to" is Do Nothing.
    var globeKeyDoesNothing: Bool
    var microphone: Permission
    var speech: Permission
    /// Why Apple Intelligence is not ready, or nil when it is.
    var appleIntelligence: String?
    var speakerModels: Bool
    /// Why meetings are not being saved, or nil when they are.
    var meetingsNotSaved: String?

    /// One thing Nscribe checks, whether it is fine or not, and the articles whose
    /// questions it bears on.
    struct Check: Identifiable, Hashable, Sendable {
        let id: String
        let isFine: Bool
        /// What is true, said either way: "Accessibility is on for Nscribe."
        let sentence: String
        /// The way to fix it, when it is not fine.
        let action: HelpArticle.Action?
        /// When not fine, shown on Help's opening screen. The rest only beside an
        /// answer about them.
        let isUrgent: Bool
        let articles: Set<HelpArticle.ID>
        /// The article that fixes it, which a question about something not working is
        /// answered from while the problem stands.
        var fixArticle: HelpArticle.ID? = nil
    }

    var checks: [Check] {
        let keyArticles: Set<HelpArticle.ID> = ["key-does-nothing", "first-dictation", "dictation-key", "hands-free"]
        var found: [Check] = [
            Check(id: "accessibility", isFine: accessibility,
                  sentence: accessibility
                    ? "Accessibility is on for Nscribe."
                    : "Accessibility is off for Nscribe, so the dictation key does nothing and Nscribe can't type into other apps.",
                  action: .accessibilitySettings, isUrgent: true,
                  articles: keyArticles.union(["permissions", "copied-not-typed"]),
                  fixArticle: "key-does-nothing")
        ]
        if accessibility {
            found.append(Check(
                id: "key", isFine: keyError == nil,
                sentence: keyError.map { "The dictation key isn't working. \($0)" } ?? "The dictation key is listening.",
                action: .nscribeSettings(.dictation), isUrgent: true, articles: keyArticles,
                fixArticle: "key-does-nothing"))
        }
        if usesGlobeKey {
            found.append(Check(
                id: "globe", isFine: globeKeyDoesNothing,
                sentence: globeKeyDoesNothing
                    ? "macOS's \"Press 🌐 key to\" setting is Do Nothing, so macOS leaves the Globe key to Nscribe."
                    : "macOS also acts on the Globe key, so each press opens emoji or switches your input source as well.",
                action: .keyboardSettings, isUrgent: true,
                articles: keyArticles.union(["globe-key-emoji"]), fixArticle: "globe-key-emoji"))
        }
        let microphoneSentence = switch microphone {
        case .allowed: "Nscribe is allowed to use the microphone."
        case .notAsked: "macOS has not asked about the microphone yet; it asks at the first dictation."
        case .refused: "Nscribe isn't allowed to use the microphone, so it hears nothing."
        }
        found.append(Check(
            id: "microphone", isFine: microphone != .refused, sentence: microphoneSentence,
            action: .microphoneSettings, isUrgent: true,
            articles: ["nothing-heard", "microphone", "permissions", "first-dictation", "start-meeting", "microphone-busy"],
            fixArticle: "nothing-heard"))
        let speechSentence = switch speech {
        case .allowed: "Nscribe is allowed to use speech recognition."
        case .notAsked: "macOS has not asked about speech recognition yet; it asks at the first dictation."
        case .refused: "Nscribe isn't allowed to use speech recognition, so it can't turn what you say into text."
        }
        found.append(Check(
            id: "speech", isFine: speech != .refused, sentence: speechSentence,
            action: .speechSettings, isUrgent: true,
            articles: ["nothing-heard", "permissions", "first-dictation", "language"],
            fixArticle: "nothing-heard"))
        found.append(Check(
            id: "apple-intelligence", isFine: appleIntelligence == nil,
            sentence: appleIntelligence.map {
                "Apple Intelligence isn't ready, so rewriting, meeting summaries and answers in Help are off. \($0)"
            } ?? "Apple Intelligence is ready.",
            action: .nscribeSettings(.dictation), isUrgent: true,
            articles: ["apple-intelligence", "rewrite-failed", "choose-prompt", "custom-prompt",
                       "keep-my-words", "meeting-summary", "ask-nscribe"],
            fixArticle: "apple-intelligence"))
        found.append(Check(
            id: "meetings", isFine: meetingsNotSaved == nil,
            sentence: meetingsNotSaved.map { "Meetings aren't being saved. \($0)" } ?? "Meetings are being saved.",
            action: nil, isUrgent: true,
            articles: ["start-meeting", "stored-data", "delete-meeting", "search-meetings"]))
        found.append(Check(
            id: "speaker-models", isFine: speakerModels,
            sentence: speakerModels
                ? "The speaker models are installed."
                : "The speaker models aren't installed, so meetings have no speaker names.",
            action: .nscribeSettings(.meetings), isUrgent: false,
            articles: ["no-speaker-names", "speaker-names", "old-meeting-speakers"],
            fixArticle: "no-speaker-names"))
        return found
    }

    /// What keeps part of Nscribe from working.
    var problems: [Check] { checks.filter { !$0.isFine } }

    /// The checks that bear on these articles, fine or not.
    func checks(for articles: Set<HelpArticle.ID>) -> [Check] {
        checks.filter { !$0.articles.isDisjoint(with: articles) }
    }
}
