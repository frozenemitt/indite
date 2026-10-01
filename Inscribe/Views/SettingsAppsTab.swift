import SwiftUI
import UniformTypeIdentifiers

// MARK: - Per-App Profiles

struct AppProfilesSettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(PromptConfiguration.self) private var promptConfig

    @State private var profiles: [AppProfile] = []

    var body: some View {
        Form {
            ForEach($profiles) { $profile in
                Section {
                    Toggle(profile.appName, isOn: $profile.isEnabled)
                        .font(.headline)
                        .onChange(of: profile.isEnabled) { _, _ in commit() }

                    Picker("Prompt", selection: Binding(
                        get: { profile.promptId },
                        set: { profile.promptId = $0; commit() }
                    )) {
                        Text("Use the default").tag(nil as UUID?)
                        Text("Off").tag(PromptConfiguration.rawPromptId as UUID?)
                        // Every prompt, not just the visible ones: hidden means hidden
                        // from the menu bar dropdown, and a profile already pointing at
                        // one would otherwise show an empty picker.
                        ForEach(promptConfig.rewritingPrompts) { prompt in
                            Text(prompt.name).tag(prompt.id as UUID?)
                        }
                    }
                    .disabled(!profile.isEnabled)

                    Picker("Output", selection: Binding(
                        get: { profile.outputModeRaw },
                        set: { profile.outputModeRaw = $0; commit() }
                    )) {
                        Text("Use the default").tag(nil as String?)
                        ForEach(OutputMode.allCases) { mode in
                            Text(mode.displayName).tag(mode.rawValue as String?)
                        }
                    }
                    .disabled(!profile.isEnabled)

                    Picker("Press Return after typing", selection: Binding(
                        get: { profile.autoSubmit },
                        set: { profile.autoSubmit = $0; commit() }
                    )) {
                        Text("Use the default").tag(nil as Bool?)
                        Text("Yes").tag(true as Bool?)
                        Text("No").tag(false as Bool?)
                    }
                    .disabled(!profile.isEnabled)

                    Button("Remove Profile", role: .destructive) {
                        profiles.removeAll { $0.id == profile.id }
                        commit()
                    }
                    .buttonStyle(.borderless)
                }
            }

            Section {
                Button("Add App…", systemImage: "plus") {
                    addApp()
                }
                .buttonStyle(.borderless)
            } footer: {
                Text("A profile overrides the prompt or output for one app. The app you start talking in picks the prompt. The app in front when the text is ready decides how it arrives.")
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: load)
    }

    private func load() {
        profiles = settings.appProfiles.values
            .sorted { $0.appName.localizedCaseInsensitiveCompare($1.appName) == .orderedAscending }
    }

    private func commit() {
        settings.appProfiles = Dictionary(
            uniqueKeysWithValues: profiles.map { ($0.bundleIdentifier, $0) }
        )
    }

    /// Choose an app from the Applications folder, as System Settings does for login
    /// items, so it need not be running and the user never types a bundle identifier.
    private func addApp() {
        guard let window = NSApp.keyWindow else { return }

        let panel = NSOpenPanel()
        panel.directoryURL = URL(filePath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false

        // Apps that already have a profile are greyed out. Chosen, they closed the
        // panel and changed nothing, which looked like a failed add.
        let filter = ExistingProfileFilter(taken: Set(profiles.map(\.bundleIdentifier)))
        panel.delegate = filter

        // A sheet on the Settings window. Run modally, the panel floated free of the
        // window and blocked every other one in the app, the menu bar's Stop Meeting
        // included.
        Task {
            let response = await panel.beginSheetModal(for: window)
            // The panel holds its delegate weakly, so the filter is kept alive here
            // until the sheet has closed.
            withExtendedLifetime(filter) {}

            guard response == .OK,
                  let url = panel.url,
                  let bundle = Bundle(url: url),
                  let bundleID = bundle.bundleIdentifier else { return }
            // The filter cannot see through a Finder alias, which the panel resolves
            // to the app it points at. commit() cannot hold two profiles for one app.
            guard !profiles.contains(where: { $0.bundleIdentifier == bundleID }) else { return }

            let name = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
                ?? url.deletingPathExtension().lastPathComponent

            profiles.append(AppProfile(
                bundleIdentifier: bundleID,
                appName: name,
                promptId: nil,
                outputModeRaw: nil,
                autoSubmit: nil
            ))
            profiles.sort { $0.appName.localizedCaseInsensitiveCompare($1.appName) == .orderedAscending }
            commit()
        }
    }
}

/// Greys out apps that already have a profile in the Add App panel.
@MainActor
private final class ExistingProfileFilter: NSObject, NSOpenSavePanelDelegate {
    private let taken: Set<String>

    init(taken: Set<String>) {
        self.taken = taken
    }

    func panel(_ sender: Any, shouldEnable url: URL) -> Bool {
        // Folders stay enabled so the user can still open them.
        guard url.pathExtension == "app" else { return true }
        return !taken.contains(Bundle(url: url)?.bundleIdentifier ?? "")
    }
}
