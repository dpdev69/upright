import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Pop-up menu that picks what a button (or a gesture slot) does, grouped like the system's own
/// lists. Shows a shortcut recorder next to the menu while a keyboard shortcut is selected.
///
/// With `allowsGestures` off (gesture slots), "Gestures…" is hidden and so is "Default": a slot's
/// button is always diverted, so `.deviceDefault` there means the same as "Do Nothing".
struct ActionPicker: View {
    @Binding var selection: ButtonAction
    let allowsGestures: Bool

    @ObservedObject private var settings = AppModel.shared.settings
    @State private var isRecording = false
    @State private var wantsShortcut = false
    @State private var textEntry: TextEntryKind?

    init(selection: Binding<ButtonAction>, allowsGestures: Bool = true) {
        _selection = selection
        self.allowsGestures = allowsGestures
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if case .keyCombo(let combo) = selection {
                ShortcutRecorder(combo: combo, isRecording: $isRecording, onRecord: { selection = .keyCombo($0) }, onClear: clear)
            } else if wantsShortcut {
                ShortcutRecorder(combo: nil, isRecording: $isRecording, onRecord: { selection = .keyCombo($0) }, onClear: clear)
            }
            menu
        }
        .onChange(of: isRecording) { recording in
            if !recording { wantsShortcut = false }
        }
        .sheet(item: $textEntry) { kind in
            TextEntrySheet(kind: kind, initialText: initialText(for: kind)) { action in
                selection = action
            }
        }
    }

    private var menu: some View {
        Menu {
            Picker(selection: $selection) {
                if allowsGestures {
                    Label("Default", systemImage: "computermouse").tag(ButtonAction.deviceDefault)
                }
                Label("Do Nothing", systemImage: "nosign").tag(ButtonAction.disabled)
                if !isListed(selection) {
                    Label(displayTitle, systemImage: selection.symbolName).tag(selection)
                }
            } label: {
                Text("Basic")
            }
            .pickerStyle(.inline)
            .labelsHidden()

            Divider()

            ForEach(SystemAction.Category.allCases, id: \.self) { category in
                Menu(category.title) {
                    Picker(selection: $selection) {
                        ForEach(SystemAction.actions(in: category)) { system in
                            Label(system.title, systemImage: system.symbolName).tag(ButtonAction.system(system))
                        }
                    } label: {
                        Text(category.title)
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }
            }

            Menu("Pointer Speed") {
                Picker(selection: $selection) {
                    Label("Cycle Pointer Speed", systemImage: "speedometer").tag(ButtonAction.device(.cycleDPI))
                    ForEach(settings.dpiPresets, id: \.self) { dpi in
                        Text("Set to \(dpi) DPI").tag(ButtonAction.device(.setDPI(dpi)))
                    }
                } label: {
                    Text("Pointer Speed")
                }
                .pickerStyle(.inline)
                .labelsHidden()
                Divider()
                Button("Edit Presets…") { AppModel.shared.selectedPane = .device }
            }

            Menu("Easy-Switch") {
                Picker(selection: $selection) {
                    ForEach(Array(DeviceAction.hostRange), id: \.self) { host in
                        Text("Switch to Computer \(host)").tag(ButtonAction.device(.switchHost(host)))
                    }
                } label: {
                    Text("Easy-Switch")
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }

            Divider()

            Button {
                wantsShortcut = true
                isRecording = true
            } label: {
                Label("Keyboard Shortcut…", systemImage: "keyboard")
            }
            Button {
                if let app = AppChooser.chooseApplication() { selection = .launchApp(app) }
            } label: {
                Label("Open App…", systemImage: "app")
            }
            Button {
                textEntry = .url
            } label: {
                Label("Open URL…", systemImage: "link")
            }
            Button {
                textEntry = .shortcut
            } label: {
                Label("Run Shortcut…", systemImage: "square.2.layers.3d")
            }

            if allowsGestures {
                Divider()
                Button {
                    if !selection.isGestures { selection = .gestures(.standard) }
                } label: {
                    Label("Gestures…", systemImage: "hand.draw")
                }
            }
        } label: {
            Label(displayTitle, systemImage: displaySymbol)
                .lineLimit(1)
        }
        .fixedSize()
        .help(selection.helpText)
        .accessibilityLabel(Text("Action"))
        .accessibilityValue(Text(displayTitle))
    }

    /// Delete in the shortcut recorder clears the button (or empties the gesture slot).
    private func clear() {
        wantsShortcut = false
        selection = allowsGestures ? .deviceDefault : .disabled
    }

    private var displayTitle: String {
        switch selection {
        case .keyCombo: return String(localized: "Keyboard Shortcut")
        case .deviceDefault where !allowsGestures: return ButtonAction.disabled.title
        default: return selection.title
        }
    }

    private var displaySymbol: String {
        if !allowsGestures, selection == .deviceDefault { return ButtonAction.disabled.symbolName }
        return selection.symbolName
    }

    /// Whether the menu already has a checkable item for the action.
    private func isListed(_ action: ButtonAction) -> Bool {
        switch action {
        case .deviceDefault: return allowsGestures
        case .disabled, .system: return true
        case .device(.cycleDPI), .device(.switchHost): return true
        case .device(.setDPI(let dpi)): return settings.dpiPresets.contains(dpi)
        case .keyCombo, .launchApp, .openURL, .runShortcut, .gestures: return false
        }
    }

    private func initialText(for kind: TextEntryKind) -> String {
        switch (kind, selection) {
        case (.url, .openURL(let url)): return url.absoluteString
        case (.shortcut, .runShortcut(let name)): return name
        default: return ""
        }
    }
}

// MARK: Choosing apps

enum AppChooser {
    /// Shows an open panel for an application bundle. Nil when cancelled or the app has no bundle ID.
    @MainActor
    static func chooseApplication(prompt: String = String(localized: "Choose")) -> AppReference? {
        chooseApplicationURL(prompt: prompt).flatMap(reference(for:))
    }

    @MainActor
    static func chooseApplicationURL(prompt: String) -> URL? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.prompt = prompt
        return panel.runModal() == .OK ? panel.url : nil
    }

    static func reference(for url: URL) -> AppReference? {
        guard let bundleID = Bundle(url: url)?.bundleIdentifier else { return nil }
        var name = FileManager.default.displayName(atPath: url.path)
        if name.hasSuffix(".app") { name = String(name.dropLast(4)) }
        return AppReference(bundleID: bundleID, displayName: name)
    }
}

// MARK: URL and shortcut entry

enum TextEntryKind: String, Identifiable {
    case url
    case shortcut

    var id: String { rawValue }
}

/// A small sheet asking for a URL or a Shortcuts.app shortcut name.
private struct TextEntrySheet: View {
    let kind: TextEntryKind
    let onDone: (ButtonAction) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    @State private var shortcuts: [String]?

    init(kind: TextEntryKind, initialText: String, onDone: @escaping (ButtonAction) -> Void) {
        self.kind = kind
        self.onDone = onDone
        _text = State(initialValue: initialText)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(kind == .url ? "Open URL" : "Run Shortcut")
                .font(.headline)
            Text(kind == .url
                 ? "Opens a web page, a new email (mailto:) or an app link such as slack://."
                 : "Runs a shortcut from the Shortcuts app by its exact name.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            TextField(kind == .url ? "https://example.com" : "Shortcut name", text: $text)
                .textFieldStyle(.roundedBorder)
                .onSubmit(commit)
                .accessibilityLabel(kind == .url ? Text("URL") : Text("Shortcut name"))

            if kind == .url, !trimmed.isEmpty, action == nil {
                Label("Enter a web address such as https://example.com, a mailto: link or an app link. File links aren’t supported.", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            if kind == .shortcut {
                shortcutList
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("OK", action: commit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(action == nil)
            }
        }
        .padding(20)
        .frame(minWidth: 380, idealWidth: 420)
        .task {
            guard kind == .shortcut, shortcuts == nil else { return }
            shortcuts = await ShortcutsLibrary.names()
        }
    }

    @ViewBuilder
    private var shortcutList: some View {
        if let shortcuts {
            let matches = trimmed.isEmpty ? shortcuts : shortcuts.filter { $0.localizedCaseInsensitiveContains(trimmed) }
            if !matches.isEmpty {
                List(matches, id: \.self) { name in
                    Button {
                        text = name
                    } label: {
                        HStack {
                            Text(name)
                            Spacer()
                            if name == trimmed {
                                Image(systemName: "checkmark").foregroundStyle(.tint)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .frame(minHeight: 120, maxHeight: 180)
                .accessibilityLabel(Text("Your shortcuts"))
            }
        } else {
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var action: ButtonAction? {
        guard !trimmed.isEmpty else { return nil }
        switch kind {
        case .url:
            return URLValidation.url(from: trimmed).map(ButtonAction.openURL)
        case .shortcut:
            return .runShortcut(trimmed)
        }
    }

    private func commit() {
        guard let action else { return }
        onDone(action)
        dismiss()
    }
}

enum URLValidation {
    /// A usable URL from what the user typed; "example.com" becomes "https://example.com".
    /// App links such as "slack://" are fine when typed here, but `file:` links are rejected
    /// because opening one can run a local program. Imported files are stricter
    /// (`ButtonAction.allowedURLSchemes`), since their links weren't typed by the user.
    static func url(from input: String) -> URL? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.contains(" ") else { return nil }
        let hasScheme = text.range(of: "^[A-Za-z][A-Za-z0-9+.-]*:", options: .regularExpression) != nil
        if hasScheme, let url = validated(text) { return url }
        // "localhost:3000" or "example.com:8080/a" look like they start with a scheme.
        guard !hasScheme || !text.contains("//") else { return nil }
        return validated("https://" + text)
    }

    private static func validated(_ candidate: String) -> URL? {
        guard let url = URL(string: candidate), let scheme = url.scheme?.lowercased(), scheme != "file" else { return nil }
        if scheme == "http" || scheme == "https" {
            guard let host = url.host, host.contains(".") || host == "localhost" else { return nil }
        }
        return url
    }
}

/// Lists the user's shortcuts with `/usr/bin/shortcuts list`, off the main thread.
enum ShortcutsLibrary {
    static func names() async -> [String] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: run())
            }
        }
    }

    private static func run() -> [String] {
        let executable = URL(fileURLWithPath: "/usr/bin/shortcuts")
        guard FileManager.default.isExecutableFile(atPath: executable.path) else { return [] }
        let process = Process()
        process.executableURL = executable
        process.arguments = ["list"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return []
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return [] }
        return String(decoding: data, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
}
