import AppKit
import SwiftUI

/// Picks which of a model's mapping tables the Buttons pane edits (global or one app's
/// overrides), adds and removes that model's app profiles, and says which profile is in effect
/// right now. App profiles are per model: adding one for an app never touches another model's.
struct ProfileSection: View {
    @EnvironmentObject private var appModel: AppModel
    /// The model whose profiles are listed and edited.
    let modelKey: ModelKey
    /// nil edits the global table.
    @Binding var selectedBundleID: String?

    @State private var confirmingRemoval = false
    @State private var addFailed = false

    init(model: ModelKey, selectedBundleID: Binding<String?>) {
        modelKey = model
        _selectedBundleID = selectedBundleID
    }

    /// The model's setup (global table and app profiles).
    private var profiles: MappingProfiles {
        appModel.library[modelKey]
    }

    var body: some View {
        Section {
            HStack(spacing: 10) {
                Picker(selection: $selectedBundleID) {
                    Label {
                        Text("All Apps (Global)")
                    } icon: {
                        Image(systemName: "globe")
                    }
                    .tag(String?.none)
                    if !profiles.apps.isEmpty {
                        Divider()
                    }
                    ForEach(profiles.apps) { app in
                        Label {
                            Text(app.isEnabled ? app.displayName : String(localized: "\(app.displayName) (off)"))
                        } icon: {
                            AppIconImage(bundleID: app.bundleID)
                        }
                        .tag(Optional(app.bundleID))
                    }
                } label: {
                    Text("Edit mappings for")
                }
                .snapshotAnchor("profilePicker")
                addMenu
            }

            if let profile = selectedProfile {
                Toggle(isOn: Binding(
                    get: { profile.isEnabled },
                    set: { appModel.setAppProfileEnabled($0, bundleID: profile.bundleID, model: modelKey) }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Use this profile")
                        Text("While \(profile.displayName) is the frontmost app, its overrides replace the global actions.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                HStack {
                    Text(profile.bundleID)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    Spacer()
                    Button("Remove Profile…", role: .destructive) { confirmingRemoval = true }
                }
            }
        } header: {
            Text("Profile")
        } footer: {
            activeNow
        }
        .confirmationDialog(
            Text("Remove the profile for \(selectedProfile?.displayName ?? "")?"),
            isPresented: $confirmingRemoval,
            titleVisibility: .visible
        ) {
            Button("Remove Profile", role: .destructive) {
                guard let bundleID = selectedBundleID else { return }
                selectedBundleID = nil
                appModel.removeAppProfile(bundleID: bundleID, model: modelKey)
            }
        } message: {
            Text("Its overrides are deleted. The app goes back to using the global actions.")
        }
        .alert(Text("That app can’t have a profile"), isPresented: $addFailed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Upright couldn’t read a bundle identifier from it.")
        }
        .onChange(of: profiles.apps.map(\.bundleID)) { ids in
            if let selected = selectedBundleID, !ids.contains(where: { $0.caseInsensitiveCompare(selected) == .orderedSame }) {
                selectedBundleID = nil
            }
        }
    }

    private var selectedProfile: AppProfile? {
        selectedBundleID.flatMap { profiles[app: $0] }
    }

    private var addMenu: some View {
        Menu {
            let running = runningApps
            if !running.isEmpty {
                Section("Running Apps") {
                    ForEach(running, id: \.bundleID) { app in
                        Button {
                            add(app)
                        } label: {
                            Label {
                                Text(app.displayName)
                            } icon: {
                                AppIconImage(bundleID: app.bundleID)
                            }
                        }
                    }
                }
                Divider()
            }
            Button("Choose Another App…") {
                guard let url = AppChooser.chooseApplicationURL(prompt: String(localized: "Add Profile")) else { return }
                if let app = AppChooser.reference(for: url) {
                    add(app)
                } else {
                    addFailed = true
                }
            }
        } label: {
            Label("Add App", systemImage: "plus")
        }
        .fixedSize()
        .help("Add a profile with different actions for one app")
    }

    @ViewBuilder
    private var activeNow: some View {
        let frontmost = appModel.frontmostApp
        Group {
            if let active = profiles.enabledProfile(forBundleID: frontmost?.bundleID) {
                Text("In effect now: the \(active.displayName) profile.")
            } else if let frontmost {
                Text("In effect now: the global actions (\(frontmost.name) has no active profile).")
            } else {
                Text("In effect now: the global actions.")
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .snapshotAnchor("inEffect")
    }

    /// Regular apps that are running and don't have a profile yet, by name.
    private var runningApps: [AppReference] {
        let own = Bundle.main.bundleIdentifier
        var seen = Set<String>()
        return NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app -> AppReference? in
                guard let id = app.bundleIdentifier, id != own, profiles[app: id] == nil,
                      seen.insert(id.lowercased()).inserted else { return nil }
                return AppReference(bundleID: id, displayName: app.localizedName ?? id)
            }
            .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    private func add(_ app: AppReference) {
        appModel.addAppProfile(bundleID: app.bundleID, displayName: app.displayName, model: modelKey)
        selectedBundleID = appModel.library[modelKey][app: app.bundleID]?.bundleID ?? app.bundleID
    }
}

/// The Finder icon of an installed app, or a generic app symbol.
struct AppIconImage: View {
    let bundleID: String
    var size: CGFloat = 16

    var body: some View {
        if let icon = Self.icon(for: bundleID) {
            Image(nsImage: icon)
                .resizable()
                .frame(width: size, height: size)
                .accessibilityHidden(true)
        } else {
            Image(systemName: "app")
                .accessibilityHidden(true)
        }
    }

    @MainActor private static var cache: [String: NSImage] = [:]

    @MainActor
    static func icon(for bundleID: String) -> NSImage? {
        if let cached = cache[bundleID] { return cached }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let image = NSWorkspace.shared.icon(forFile: url.path)
        image.size = NSSize(width: 32, height: 32)
        cache[bundleID] = image
        return image
    }
}
