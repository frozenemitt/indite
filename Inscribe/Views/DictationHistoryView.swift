import SwiftUI
import SwiftData

#if os(macOS)

/// Recent dictations, so one that landed in the wrong window is recoverable.
struct DictationHistoryView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(RecordingCoordinator.self) private var coordinator
    @Environment(\.modelContext) private var modelContext

    @Query(sort: \Dictation.createdAt, order: .reverse) private var dictations: [Dictation]

    @State private var searchText = ""
    @State private var justCopied: CopiedKind?
    @State private var isConfirmingClearAll = false

    /// Which copy button last completed, so only that button's own label flips —
    /// not its sibling, which copies a different string for the same dictation.
    private enum CopiedKind: Equatable {
        case cleaned(PersistentIdentifier)
        case original(PersistentIdentifier)
    }

    /// Matches the original transcript as well as the delivered text: the user
    /// remembers the words they said, which the AI may have rewritten.
    private var filtered: [Dictation] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return dictations }
        return dictations.filter {
            $0.text.localizedStandardContains(query)
                || ($0.rawText?.localizedStandardContains(query) ?? false)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // The banner shows only while older entries are still listed. With none
            // left, the empty state below already says that history is off.
            if !settings.keepDictationHistory && !dictations.isEmpty {
                Label("History is switched off in Settings, so nothing new is being kept.",
                      systemImage: "exclamationmark.circle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.orange.opacity(0.12))
            }

            if dictations.isEmpty {
                if settings.keepDictationHistory {
                    ContentUnavailableView(
                        "No Dictations Yet",
                        systemImage: "clock.arrow.circlepath",
                        description: Text("Finished dictations appear here.")
                    )
                } else {
                    ContentUnavailableView {
                        Label("History Is Off", systemImage: "clock.arrow.circlepath")
                    } description: {
                        Text("Turn on \u{201C}Keep recent dictations\u{201D} in Settings.")
                    } actions: {
                        SettingsLink {
                            Text("Open Settings\u{2026}")
                        }
                    }
                }
            } else if filtered.isEmpty {
                ContentUnavailableView.search(text: searchText)
            } else {
                list
            }
        }
        .frame(minWidth: 480, minHeight: 320)
        .navigationTitle("Dictation History")
        .searchable(text: $searchText, placement: .toolbar, prompt: "Search dictations")
        .toolbar {
            ToolbarItem {
                Button("Clear All", role: .destructive) {
                    isConfirmingClearAll = true
                }
                .disabled(dictations.isEmpty)
                .confirmationDialog(
                    dictations.count == 1 ? "Delete 1 dictation?" : "Delete all \(dictations.count) dictations?",
                    isPresented: $isConfirmingClearAll,
                    titleVisibility: .visible
                ) {
                    Button("Delete All", role: .destructive) {
                        DictationHistory.clear(in: modelContext)
                    }
                    Button("Cancel", role: .cancel) { }
                } message: {
                    Text("This cannot be undone.")
                }
            }
        }
    }

    private var list: some View {
        List {
            ForEach(filtered) { dictation in
                let countLabel = dictation.characterCount == 1
                    ? "1 character" : "\(dictation.characterCount) characters"

                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        timestamp(for: dictation)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()

                        if let destination = dictation.destination {
                            Text("→ \(destination)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        if let prompt = dictation.promptName {
                            Text(prompt)
                                .font(.caption2)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(Color.secondary.opacity(0.15)))
                        }

                        Spacer()

                        Text("\(dictation.characterCount)")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .monospacedDigit()
                            .help(countLabel)
                            .accessibilityLabel(countLabel)
                    }

                    Text(dictation.text)
                        .textSelection(.enabled)
                        .lineLimit(4)

                    HStack(spacing: 12) {
                        Button {
                            ClipboardService.copy(dictation.text)
                            confirmCopy(.cleaned(dictation.persistentModelID))
                        } label: {
                            Label(
                                justCopied == .cleaned(dictation.persistentModelID) ? "Copied" : "Copy",
                                systemImage: justCopied == .cleaned(dictation.persistentModelID)
                                    ? "checkmark" : "doc.on.doc"
                            )
                        }

                        // The reason history exists: put it where it should have gone.
                        Button {
                            insert(dictation)
                        } label: {
                            Label("Insert", systemImage: "text.cursor")
                        }

                        if dictation.wasEditedByAI, let raw = dictation.rawText {
                            Button {
                                ClipboardService.copy(raw)
                                confirmCopy(.original(dictation.persistentModelID))
                            } label: {
                                Label(
                                    justCopied == .original(dictation.persistentModelID) ? "Copied" : "Copy Original",
                                    systemImage: justCopied == .original(dictation.persistentModelID)
                                        ? "checkmark" : "arrow.uturn.backward"
                                )
                            }
                            .help("The transcript before the AI rewrote it")
                        }

                        Spacer()

                        Button(role: .destructive) {
                            modelContext.delete(dictation)
                            modelContext.saveOrLog()
                        } label: {
                            Label("Delete", systemImage: "trash")
                                .labelStyle(.iconOnly)
                        }
                        .help("Delete this dictation")
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                }
                .padding(.vertical, 4)
            }
        }
    }

    /// The time alone for something dictated today; the date and time otherwise, so
    /// a week-old entry does not read as though it just happened.
    private func timestamp(for dictation: Dictation) -> Text {
        if Calendar.current.isDateInToday(dictation.createdAt) {
            return Text(dictation.createdAt, style: .time)
        }
        return Text(dictation.createdAt, format: .dateTime.month(.abbreviated).day().hour().minute())
    }

    /// Show the checkmark, then take it back.
    ///
    /// Nothing else in the row ever clears it, so a row left showing "Copied" would
    /// still claim a copy that happened an hour ago.
    private func confirmCopy(_ kind: CopiedKind) {
        justCopied = kind
        Task {
            try? await Task.sleep(for: .seconds(2))
            if justCopied == kind {
                justCopied = nil
            }
        }
    }

    /// Send it to the app the user was in before coming to this window.
    ///
    /// Deliberately not the app it originally went to: the point is usually that the
    /// first destination was wrong. Not the frontmost app either, which is Inscribe
    /// itself, whose focused field is this window's search box.
    private func insert(_ dictation: Dictation) {
        Task {
            // deliver brings the target in front of this window and waits until it is
            // there. Hiding Inscribe first, as this used to, also hid the meeting
            // indicator and guessed at how long the next app took to come forward.
            let outcome = await TextInsertionService.deliver(
                dictation.text,
                targetApp: coordinator.appInFront,
                restoreClipboard: settings.restoreClipboardAfterPaste,
                autoSubmit: false
            )

            // Reported as a notification rather than in-window text: the target app
            // is now in front of this window, so a banner drawn here would report the
            // outcome somewhere the user is no longer looking. "Clipboard" makes the
            // notification say the text was copied, so the user knows to paste it.
            let destination = switch outcome {
            case .inserted(let appName): appName
            case .copiedToClipboard: "Clipboard"
            }
            NotificationService.shared.showTranscriptionCompleteIfEnabled(
                characterCount: dictation.text.count,
                destination: destination,
                settings: settings
            )
        }
    }
}
#endif
