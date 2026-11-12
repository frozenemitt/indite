import SwiftUI

// MARK: - Meetings Settings

/// Everything about a meeting: what is recorded, what is written when it ends, and
/// the models that tell speakers apart.
///
/// These used to be split between the Dictation tab and the Output tab.
struct MeetingsSettingsView: View {
    @Environment(AppSettings.self) private var settings

    /// Disk used by saved recordings, measured once when the tab appears. Read in the
    /// body, it listed the recordings folder twice on every redraw.
    @State private var recordingsSize: Int64 = 0

    var body: some View {
        @Bindable var settings = settings

        Form {
            Section("Recording") {
                Toggle("Keep the recording after a meeting ends", isOn: $settings.keepMeetingAudio)
                    .onAppear { recordingsSize = MeetingAudioStore.totalSize() }

                Text(recordingsSize > 0
                     ? "About 30 MB an hour. Recordings use \(recordingsSize.formatted(.byteCount(style: .file))) now."
                     : "About 30 MB an hour.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("Also record the other people on a call", isOn: $settings.captureSystemAudioInMeetings)

                if settings.captureSystemAudioInMeetings {
                    // Nothing here tests the permission. The only test creates a tap, and
                    // a refused permission may not refuse one, so the test could report
                    // access macOS never gave. It also held the main thread while the audio
                    // server answered. A meeting reports system audio that stays silent, so
                    // the link names the permission to check rather than saying whether it
                    // was given.
                    Button("Allow Indite in Screen & System Audio Recording…") {
                        SystemAudioCapture.openSystemSettings()
                    }
                    .buttonStyle(.link)

                    Text("Records the sound that comes out of your Mac, so everyone you can hear on the call is recorded, and not only you. Ask the people you are meeting whether they agree to be recorded.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            Section("During a Meeting") {
                Toggle("Show the floating meeting controls", isOn: $settings.showMeetingIndicator)
                    .help("A small floating bar that shows the meeting is being recorded, with a clock and Pause and Stop buttons.")
            }

            Section("When a Meeting Ends") {
                Toggle("Write a title and a summary", isOn: $settings.summarizeMeetingsAtEnd)
                    .help("Written on this Mac by Apple Intelligence.")
            }

            DiarizationModelsSection()
        }
        .formStyle(.grouped)
    }
}

// MARK: - Speaker Models

/// Status and updates for the CoreML speaker models.
///
/// FluidAudio downloads these once and never looks again — its only test is whether
/// the file exists, so an install keeps whatever the repository held that day forever.
/// This is the missing half: check the installed files against the hashes the
/// repository publishes, and replace them on request.
struct DiarizationModelsSection: View {

    @State private var isInstalled = false
    @State private var sizeLabel = ""
    @State private var installedAt: Date?

    @State private var isChecking = false
    @State private var isUpdating = false
    @State private var isInstalling = false
    @State private var installError: String?
    @State private var checkResult: CheckResult?

    enum CheckResult: Equatable {
        case upToDate(Date?)
        case updateAvailable(Date?, changedFiles: Int)
        case failed(String)
    }

    var body: some View {
        Section("Speaker Names") {
            status
                .onAppear(perform: refresh)

            if isInstalled {
                HStack(spacing: 12) {
                    Button {
                        check()
                    } label: {
                        if isChecking {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text("Checking…")
                            }
                        } else {
                            Text("Check for Updates")
                        }
                    }
                    .disabled(isChecking || isUpdating)

                    if case .updateAvailable = checkResult {
                        Button(isUpdating ? "Updating…" : "Update Now") { update() }
                            .disabled(isUpdating)
                    } else {
                        // Always reachable: a check that reports a problem must leave
                        // the user something to press.
                        Button(isUpdating ? "Downloading…" : "Download Again") { update() }
                            .disabled(isChecking || isUpdating)
                    }
                }

                if let checkResult {
                    resultLabel(checkResult)
                }

                Text("Checking and downloading connect to HuggingFace, the website that hosts these files. Nothing you say or record leaves this Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help("Checking compares the files on this Mac with the ones HuggingFace publishes. Downloading again replaces them. If the download fails, the files you have stay.")
            } else {
                Button(isInstalling ? "Installing…" : "Download and Install") { install() }
                    .disabled(isInstalling)

                if let installError {
                    Text(installError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
    }

    // MARK: Sections

    @ViewBuilder
    private var status: some View {
        if isInstalled {
            LabeledContent("Installed") {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(sizeLabel)
                    if let installedAt {
                        Text(installedAt.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        } else {
            Label("Indite can show who said what in a meeting. This needs an extra download of about 21 MB from HuggingFace, a website that hosts these files.",
                  systemImage: "arrow.down.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func resultLabel(_ result: CheckResult) -> some View {
        switch result {
        case .upToDate(let date):
            Label {
                Text(date.map { "Checked. The files match the ones published on \($0.formatted(date: .abbreviated, time: .omitted))." }
                    ?? "Checked. The files match the published ones.")
            } icon: {
                Image(systemName: "checkmark.seal.fill")
                    .foregroundStyle(.green)
            }
            .font(.caption)

        case .updateAvailable(let date, let changed):
            Label {
                Text(date.map { "\(changed) file\(changed == 1 ? "" : "s") no longer match — published \($0.formatted(date: .abbreviated, time: .omitted))" }
                    ?? "\(changed) file\(changed == 1 ? "" : "s") do not match the published models")
            } icon: {
                Image(systemName: "arrow.down.circle.fill")
                    .foregroundStyle(.orange)
            }
            .font(.caption)

        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.red)
        }
    }

    // MARK: Actions

    private func refresh() {
        isInstalled = DiarizationModelStore.isInstalled
        sizeLabel = DiarizationModelStore.sizeOnDisk.formatted(.byteCount(style: .file))
        installedAt = DiarizationModelStore.installedAt
    }

    /// Download the models, which is the only moment Indite fetches them.
    ///
    /// Recording never does this: a meeting that reached the network would make an
    /// offline app dependent on a connection at the worst possible moment.
    private func install() {
        isInstalling = true
        installError = nil

        Task {
            do {
                try await DiarizationModelStore.install()
                refresh()
            } catch {
                installError = error.localizedDescription
            }
            isInstalling = false
        }
    }

    private func check() {
        isChecking = true
        checkResult = nil

        Task {
            do {
                switch try await DiarizationModelStore.compareWithRemote() {
                case .upToDate(let date):
                    checkResult = .upToDate(date)
                case .updateAvailable(let date, let changed):
                    checkResult = .updateAvailable(date, changedFiles: changed)
                }
                refresh()
            } catch {
                checkResult = .failed(error.localizedDescription)
            }
            isChecking = false
        }
    }

    /// Replace the local copies with fresh ones, now.
    ///
    /// This used to remove them and leave the fetch to the next meeting, which is not
    /// allowed to download, so that meeting recorded without speakers.
    private func update() {
        isUpdating = true

        Task {
            do {
                try await DiarizationModelStore.reinstall()
                checkResult = nil
            } catch {
                checkResult = .failed(error.localizedDescription)
            }
            refresh()
            isUpdating = false
        }
    }
}
