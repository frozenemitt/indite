import SwiftUI

// MARK: - About Settings

struct AboutSettingsView: View {
    /// This run's own log, so a dictation that went wrong can be explained without
    /// anyone opening a terminal.
    @ViewBuilder
    private var diagnostics: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch lastRead {
            case nil:
                ProgressView()
                    .controlSize(.small)

            case .failure(let error)?:
                Text("Could not read the log: \(error.localizedDescription)")
                    .font(.caption)
                    .foregroundStyle(.orange)

            case .success(let entries)?:
                if entries.isEmpty {
                    Text("Nothing recorded yet this run. Dictate once and come back.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(entries.reversed()) { entry in
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Text(entry.date, format: .dateTime.hour().minute().second())
                                        .font(.caption2.monospacedDigit())
                                        .foregroundStyle(.tertiary)

                                    Text(entry.category)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .frame(width: 72, alignment: .leading)

                                    Text(entry.message)
                                        .font(.caption2)
                                        .foregroundStyle(entry.isProblem ? Color.orange : .primary)
                                        .textSelection(.enabled)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 220)
                }
            }

            HStack {
                Button("Refresh") { reload() }
                Button("Copy") {
                    ClipboardService.copy(Diagnostics.asText(entries))
                }
                .disabled(entries.isEmpty)
            }

            Text("Only this run, and only Inscribe. Anything you wrote or said is redacted by the system before it gets here.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.top, 8)
    }

    private func reload() {
        // Diagnostics.recent() walks the unified log, which can take real time on
        // a busy run — off the main actor so opening this disclosure group does
        // not stall the rest of the Settings window while it works.
        Task {
            lastRead = await Task.detached(priority: .utility) {
                Result { try Diagnostics.recent() }
            }.value
        }
    }

    /// Read from the bundle rather than hard-coded, so this stops matching
    /// reality the moment the app ships a new version.
    private var appVersionText: String {
        let shortVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
        return "Version \(shortVersion) (\(build))"
    }

    @Environment(AppSettings.self) private var settings
    @Environment(GlobalHotkeyMonitor.self) private var hotkeyMonitor

    /// The last read of the log, kept whole so a failed read shows as one rather
    /// than as an empty log. Nil until the first read returns.
    @State private var lastRead: Result<[Diagnostics.Entry], any Error>?
    @State private var showingDiagnostics = false
    @State private var isConfirmingReset = false

    private func resetToDefaults() {
        settings.resetToDefaults()
        // The Dictation tab re-arms on its own changes, but it is not on screen here.
        // Without this the old combination keeps firing and the restored one does
        // nothing until the app is relaunched.
        hotkeyMonitor.trigger = settings.hotkeyTrigger
        hotkeyMonitor.activationMode = settings.hotkeyActivationMode
        hotkeyMonitor.undoTrigger = settings.undoHotkeyTrigger
        hotkeyMonitor.retypeTrigger = settings.retypeHotkeyTrigger
    }

    private var entries: [Diagnostics.Entry] {
        (try? lastRead?.get()) ?? []
    }

    var body: some View {
        // Scrolls because the log can outgrow the window; the anchor keeps the page
        // centered while it fits.
        ScrollView {
            VStack(spacing: 20) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 64, height: 64)

                Text("Inscribe")
                    .font(.largeTitle)
                    .fontWeight(.bold)

                Text("Turns speech into text on the Mac")
                    .font(.headline)
                    .foregroundStyle(.secondary)

                Text(appVersionText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Divider()
                    .frame(width: 200)

                DisclosureGroup(isExpanded: $showingDiagnostics) {
                    diagnostics
                } label: {
                    Label("What Inscribe has been doing", systemImage: "stethoscope")
                        .font(.subheadline)
                }
                .frame(maxWidth: 520)
                .onChange(of: showingDiagnostics) { _, shown in
                    if shown { reload() }
                }

                Divider()
                    .frame(width: 200)

                VStack(spacing: 8) {
                    Text("Uses on-device AI for transcription and text processing.")
                    Text("Your voice data never leaves your device.")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

                Button("Reset All Settings…") {
                    isConfirmingReset = true
                }
                .confirmationDialog(
                    "Reset settings to their defaults?",
                    isPresented: $isConfirmingReset,
                    titleVisibility: .visible
                ) {
                    Button("Reset", role: .destructive) { resetToDefaults() }
                    Button("Cancel", role: .cancel) { }
                } message: {
                    Text("This also clears your word replacements, vocabulary, per-app settings and recorded key combinations. Your prompts and their settings are kept. It cannot be undone.")
                }
            }
            .padding(40)
            .frame(maxWidth: .infinity)
        }
        .defaultScrollAnchor(.center, for: .alignment)
    }
}
