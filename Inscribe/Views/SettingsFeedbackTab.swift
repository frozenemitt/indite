import SwiftUI
import UniformTypeIdentifiers

// MARK: - Feedback Settings

/// How Inscribe tells you what it is doing: the floating panels, the sounds, and the
/// notifications.
///
/// The panels used to be under Output, the sounds had a tab of their own, and the
/// notifications were in General.
struct FeedbackSettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(RecordingCoordinator.self) private var coordinator
    @Environment(SoundCatalog.self) private var soundCatalog

    @State private var importError: String?

    /// One labelled slider with its value beside it, in the form's own columns. As a
    /// row of its own with a label column of a fixed width, it lined up with nothing
    /// else in the form.
    private func solidityRow(_ label: String, value: Binding<Double>) -> some View {
        LabeledContent(label) {
            HStack(spacing: 8) {
                Slider(value: value, in: 0.25...1)
                Text(value.wrappedValue.formatted(.percent.precision(.fractionLength(0))))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 40, alignment: .trailing)
            }
        }
    }

    var body: some View {
        @Bindable var settings = settings

        Form {
            Section("Panels") {
                Toggle("Show the words as you dictate", isOn: $settings.showDictationOverlay)

                // The meeting pill reads these too, so they stay while either panel
                // is on.
                if settings.showDictationOverlay || settings.showMeetingIndicator {
                    solidityRow("Glass", value: $settings.overlayOpacity)
                    solidityRow("Words and ribbon", value: $settings.overlayContentOpacity)

                    // Both panels. It used to put back the dictation panel alone, and
                    // a meeting pill dragged onto a display since unplugged had no way
                    // home.
                    Button("Reset Panel Positions") {
                        coordinator.resetOverlayPosition()
                        settings.meetingIndicatorOriginX = nil
                        settings.meetingIndicatorOriginY = nil
                    }
                    .help("Put the dictation panel and the meeting pill back where they start. Drag either one anywhere; it comes back where you left it.")
                }
            }

            Section("Sounds") {
                Toggle("Play sounds", isOn: $settings.playFeedbackSounds)

                Group {
                    SoundPickerRow(
                        label: "Recording started",
                        selection: $settings.startSoundName,
                        sounds: soundCatalog.allSounds
                    )
                    SoundPickerRow(
                        label: "Recording stopped",
                        selection: $settings.stopSoundName,
                        sounds: soundCatalog.allSounds
                    )
                    SoundPickerRow(
                        label: "While rewriting",
                        selection: $settings.processingSoundName,
                        sounds: soundCatalog.allSounds
                    )
                    SoundPickerRow(
                        label: "Text delivered",
                        selection: $settings.completeSoundName,
                        sounds: soundCatalog.allSounds
                    )
                    SoundPickerRow(
                        label: "Something went wrong",
                        selection: $settings.errorSoundName,
                        sounds: soundCatalog.allSounds
                    )
                }
                .disabled(!settings.playFeedbackSounds)
            }

            Section("Your Sounds") {
                ForEach(soundCatalog.customSounds) { sound in
                    HStack {
                        Text(sound.displayName)

                        Spacer()

                        Button("Preview Sound", systemImage: "speaker.wave.2") {
                            SoundCatalog.shared.preview(sound.id)
                        }
                        .help("Preview Sound")

                        Button("Delete Sound", systemImage: "trash", role: .destructive) {
                            deleteSound(sound.id)
                        }
                        .help("Delete Sound")
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                }

                Button("Import Sound File…") {
                    importSoundFile()
                }

                if let importError {
                    Text(importError)
                        .foregroundStyle(.red)
                        .font(.caption)
                }
            }

            Section("Notifications") {
                Toggle("When a dictation has been delivered", isOn: $settings.showNotifications)
                Toggle("When something goes wrong", isOn: $settings.notifyOnError)
            }
        }
        .formStyle(.grouped)
    }

    private func importSoundFile() {
        guard let window = NSApp.keyWindow else { return }

        let panel = NSOpenPanel()
        panel.title = "Import Sound File"
        // Any audio type, the same test the catalog lists custom sounds by.
        panel.allowedContentTypes = [.audio]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false

        // A sheet on the Settings window. Run modally, the panel floated free of the
        // window and blocked every other one in the app.
        Task {
            guard await panel.beginSheetModal(for: window) == .OK, let url = panel.url else { return }

            do {
                try soundCatalog.importSound(from: url)
                importError = nil
            } catch {
                importError = "Failed to import: \(error.localizedDescription)"
            }
        }
    }

    private func deleteSound(_ id: String) {
        do {
            try soundCatalog.deleteCustomSound(id: id)

            // Reset any settings that reference this sound back to default, now
            // that the file is actually gone — resetting first meant a failed
            // delete still stranded the user's sound choice on a file that was
            // never removed.
            if settings.startSoundName == id { settings.startSoundName = "Morse" }
            if settings.stopSoundName == id { settings.stopSoundName = "Pop" }
            if settings.completeSoundName == id { settings.completeSoundName = "Glass" }
            if settings.errorSoundName == id { settings.errorSoundName = "Basso" }
            if settings.processingSoundName == id { settings.processingSoundName = "Bottle" }
        } catch {
            importError = "Failed to delete: \(error.localizedDescription)"
        }
    }
}

struct SoundPickerRow: View {
    let label: String
    @Binding var selection: String
    let sounds: [SoundCatalog.SoundItem]

    var body: some View {
        HStack {
            Picker(label, selection: $selection) {
                ForEach(sounds) { sound in
                    Text(sound.displayName).tag(sound.id)
                }
            }

            Button("Preview Sound", systemImage: "speaker.wave.2") {
                SoundCatalog.shared.preview(selection)
            }
            .labelStyle(.iconOnly)
            .help("Preview Sound")
            .buttonStyle(.borderless)
            .disabled(selection == SoundCatalog.noneID)
        }
    }
}
