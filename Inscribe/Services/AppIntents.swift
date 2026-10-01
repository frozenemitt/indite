import AppIntents
import os
import SwiftData
import Foundation

#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

// MARK: - Quick Transcribe Intent

/// Quick transcription intent - records for a specified duration and returns text
struct QuickTranscribeIntent: AppIntent {
    static let title: LocalizedStringResource = "Quick Transcribe"
    static let description = IntentDescription("Record your voice and get it transcribed.")

    static let openAppWhenRun: Bool = false

    @Parameter(title: "Duration", description: "Recording duration in seconds (5-300)", default: 15)
    var duration: Int

    /// Picked from the list rather than typed. A typed name had to match exactly, and
    /// a typo silently skipped the AI pass.
    @Parameter(title: "AI Prompt", description: "Optional AI processing prompt")
    var prompt: PromptEntity?

    @Parameter(title: "Copy to Clipboard", default: true)
    var copyToClipboard: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("Transcribe for \(\.$duration) seconds") {
            \.$prompt
            \.$copyToClipboard
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        // Validate duration
        let recordingDuration = min(max(duration, 5), 300)

        // The app's engine, not a new one: a second engine records over whatever the
        // app is already doing, because the guard that refuses that is instance state.
        let engine = TranscriptionEngine.shared

        // Load settings for feedback preferences
        let settings = AppSettings()

        // Whether this run's own recording started. Only that one may be cancelled on
        // the way out: a start refused as busy belongs to someone else's session, and
        // cancelling it threw away a dictation the user was in the middle of.
        var started = false

        do {
            // The same microphone, vocabulary and text rules the hotkey uses. A
            // shortcut that transcribed differently from the menu bar was the same
            // app answering the same question two ways.
            //
            // Recorded as a shortcut, not as a dictation, so the hotkey, Escape and the
            // menu bar leave it alone.
            try await engine.startRecording(
                owner: .shortcut,
                vocabulary: settings.vocabularyHints,
                inputDeviceUID: settings.inputDeviceUID
            )
            started = true

            // Sounded once capture is live, as the hotkey does, so a refused start is
            // not announced as a recording.
            AudioFeedbackService.shared.playIfEnabled(.recordingStarted, settings: settings)
            #if os(iOS)
            AudioFeedbackService.shared.playStartHaptic()
            #endif

            // Record for specified duration
            try await Task.sleep(nanoseconds: UInt64(recordingDuration) * 1_000_000_000)

            // Play stop sound
            AudioFeedbackService.shared.playIfEnabled(.recordingStopped, settings: settings)
            #if os(iOS)
            AudioFeedbackService.shared.playStopHaptic()
            #endif

            // Stop and get transcription
            let transcription = TextProcessor.process(
                await engine.stopRecording(owner: .shortcut),
                replacements: settings.wordReplacements
            )

            guard !transcription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return .result(
                    value: "",
                    dialog: "No speech was detected. Please try again."
                )
            }

            // Apply AI processing if requested, falling back to raw transcript on failure
            var finalText = transcription
            var aiFailureReason: String?
            var appliedPrompt: String?
            if let prompt {
                let promptConfig = PromptConfiguration()
                let aiProcessor = AIProcessor(promptConfiguration: promptConfig)

                if promptConfig.prompt(withId: prompt.id) != nil {
                    do {
                        finalText = try await aiProcessor.process(text: transcription, promptId: prompt.id)
                        appliedPrompt = prompt.name
                    } catch {
                        Log.intents.error("AI processing failed, using raw transcript: \(error, privacy: .public)")
                        finalText = transcription
                        aiFailureReason = "AI processing failed."
                    }
                } else {
                    // A prompt deleted since the shortcut was made. Reported rather than
                    // thrown: the recording is already spent, and the transcript is
                    // still worth handing back.
                    Log.intents.error("The shortcut's prompt no longer exists")
                    aiFailureReason = "The prompt \"\(prompt.name)\" no longer exists."
                }
            }

            // Copy to clipboard
            if copyToClipboard {
                ClipboardService.copy(finalText)
            }

            recordHistory(finalText, raw: transcription, promptName: appliedPrompt, settings: settings)

            AudioFeedbackService.shared.playIfEnabled(.processingComplete, settings: settings)

            if let aiFailureReason {
                NotificationService.shared.showAIProcessingFailedIfEnabled(
                    characterCount: finalText.count,
                    errorDetail: "\(aiFailureReason) Raw transcription was used instead.",
                    settings: settings
                )
            } else {
                NotificationService.shared.showTranscriptionCompleteIfEnabled(
                    characterCount: finalText.count,
                    destination: copyToClipboard ? "Clipboard" : nil,
                    settings: settings
                )
            }

            let dialog = if let aiFailureReason {
                copyToClipboard
                    ? "\(aiFailureReason) Raw transcription copied to clipboard."
                    : "\(aiFailureReason) Raw transcription returned."
            } else {
                copyToClipboard
                    ? "Transcription complete and copied to clipboard."
                    : "Transcription complete."
            }

            return .result(
                value: finalText,
                dialog: IntentDialog(stringLiteral: dialog)
            )

        } catch {
            // Shortcuts cancelling the run, or the system killing it for going past
            // its time limit, throws out of the sleep above. Without this the
            // microphone stays live with nothing watching it — no watchdog was armed,
            // because the coordinator was never part of this.
            if started {
                engine.cancelRecording(owner: .shortcut)
            }

            #if os(iOS)
            AudioFeedbackService.shared.playErrorHaptic()
            #endif
            AudioFeedbackService.shared.playIfEnabled(.error, settings: settings)
            throw error
        }
    }
}

// MARK: - Prompt Query

/// Entity for selecting prompts in Shortcuts
struct PromptEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "AI Prompt")

    var id: UUID
    var name: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }

    static let defaultQuery = PromptQuery()
}

struct PromptQuery: EntityQuery {
    func entities(for identifiers: [UUID]) async throws -> [PromptEntity] {
        let config = PromptConfiguration()
        return identifiers.compactMap { id in
            guard let prompt = config.prompt(withId: id) else { return nil }
            return PromptEntity(id: prompt.id, name: prompt.name)
        }
    }

    func suggestedEntities() async throws -> [PromptEntity] {
        let config = PromptConfiguration()
        return config.rewritingPrompts.map { PromptEntity(id: $0.id, name: $0.name) }
    }
}

// MARK: - History

/// Keep what a shortcut dictated, the same as the hotkey does.
///
/// A transcript that exists only in a Shortcuts result is gone the moment the user
/// dismisses it, which is exactly the case history exists for.
@MainActor
private func recordHistory(
    _ text: String,
    raw: String,
    promptName: String?,
    settings: AppSettings
) {
    #if os(macOS)
    DictationHistory.record(
        text: text,
        rawText: raw == text ? nil : raw,
        destination: "Shortcuts",
        promptName: promptName,
        settings: settings,
        in: ScribeApp.modelContainer.mainContext
    )
    #endif
}
