import AppKit
import SwiftUI

/// Picks which mapping table the Buttons pane edits (global or one app's overrides), adds and
/// removes app profiles, and says which profile is in effect right now.
struct ProfileSection: View {
    @EnvironmentObject private var model: AppModel
    /// nil edits the global table.
    @Binding var selectedBundleID: String?

    @State private var confirmingRemoval = false
    @State private var addFailed = false

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
                    if !model.profiles.apps.isEmpty {
                        Divider()
                    }
                    ForEach(model.profiles.apps) { app in
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
                addMenu
            }

            if let profile = selectedProfile {
                Toggle(isOn: Binding(
                    get: { profile.isEnabled },
                    set: { model.setAppProfileEnabled($0, bundleID: profile.bundleID) }
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
                model.removeAppProfile(bundleID: bundleID)
            }
        } message: {
            Text("Its overrides are deleted. The app goes back to using the global actions.")
        }
        .alert(Text("That app can’t have a profile"), isPresented: $addFailed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Upright couldn’t read a bundle identifier from it.")
        }
        .onChange(of: model.profiles.apps.map(\.bundleID)) { ids in
            if let selected = selectedBundleID, !ids.contains(where: { $0.caseInsensitiveCompare(selected) == .orderedSame }) {
                selectedBundleID = nil
            }
        }
    }

    private var selectedProfile: AppProfile? {
        selectedBundleID.flatMap { model.profiles[app: $0] }
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
        let frontmost = model.frontmostApp
        Group {
            if let active = model.profiles.enabledProfile(forBundleID: frontmost?.bundleID) {
                Text("In effect now: the \(active.displayName) profile.")
            } else if let frontmost {
                Text("In effect now: the global actions (\(frontmost.name) has no active profile).")
            } else {
                Text("In effect now: the global actions.")
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }

    /// Regular apps that are running and don't have a profile yet, by name.
    private var runningApps: [AppReference] {
        let own = Bundle.main.bundleIdentifier
        var seen = Set<String>()
        return NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app -> AppReference? in
                guard let id = app.bundleIdentifier, id != own, model.profiles[app: id] == nil,
                      seen.insert(id.lowercased()).inserted else { return nil }
                return AppReference(bundleID: id, displayName: app.localizedName ?? id)
            }
            .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    private func add(_ app: AppReference) {
        model.addAppProfile(bundleID: app.bundleID, displayName: app.displayName)
        selectedBundleID = model.profiles[app: app.bundleID]?.bundleID ?? app.bundleID
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
