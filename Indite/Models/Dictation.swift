import Foundation
import SwiftData

/// A finished dictation, kept so it can be recovered.
///
/// Dictation used to be delivered and forgotten, which is fine until the text lands in
/// the wrong window — a menu that stole focus, the wrong tab — and the words are simply
/// gone. Everything said is already on this Mac; keeping the last few is what makes
/// that recoverable.
@Model
final class Dictation {

    /// The text as delivered, after replacements and any AI pass.
    var text: String

    /// The words as heard, when they differ from the text: the transcript before AI
    /// processing and before any snippet was expanded, without a closing "press enter".
    ///
    /// Kept because the AI occasionally rewrites something better left alone, and the
    /// original is unrecoverable otherwise.
    var rawText: String?

    var createdAt: Date

    /// Where it went — an app name, or "Clipboard".
    var destination: String?

    /// Name of the prompt applied, if any.
    var promptName: String?

    /// How long the microphone listened, in seconds, from the moment it opened until
    /// the dictation stopped, leaving out any time the Mac slept. Recent Dictations
    /// divides the words by it for the speaking speed.
    ///
    /// Nil for dictations kept before it was recorded, and for those made by a
    /// shortcut, which records for a set time whether or not anyone is still speaking.
    /// Added in version 3 of the store.
    var spokenDuration: TimeInterval?

    init(
        text: String,
        rawText: String? = nil,
        destination: String? = nil,
        promptName: String? = nil,
        spokenDuration: TimeInterval? = nil,
        createdAt: Date = Date()
    ) {
        self.text = text
        self.rawText = rawText
        self.destination = destination
        self.promptName = promptName
        self.spokenDuration = spokenDuration
        self.createdAt = createdAt
    }

    /// Whether the AI changed anything, so the UI can offer the original.
    var wasEditedByAI: Bool {
        guard let rawText else { return false }
        return rawText != text
    }
}
