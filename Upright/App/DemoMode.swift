import Foundation

/// Launch options for Demo Mode. `--demo` runs the real UI driven by simulated mice, isolated
/// from IOKit, event taps, permission prompts and the user's settings. `--export-snapshots <dir>`
/// (which implies `--demo`) renders the UI offscreen, writes PNGs and `manifest.json` to `<dir>`,
/// then quits. See scratchpad DEMO-MODE-SPEC.md.
///
/// Wave 0 scaffold: argument parsing only. W5.5 owns this file.
enum DemoMode {
    nonisolated(unsafe) private(set) static var isActive = false
    nonisolated(unsafe) private(set) static var exportDirectory: URL?

    /// Demo Mode's own defaults domain, wiped at start; the user's is never touched.
    static let defaultsSuiteName = "io.github.upright.Upright.demo"

    static var isExporting: Bool { exportDirectory != nil }

    /// Call first thing at launch with `CommandLine.arguments`.
    static func configure(arguments: [String]) {
        exportDirectory = nil
        if let flag = arguments.firstIndex(of: "--export-snapshots"), arguments.indices.contains(flag + 1) {
            exportDirectory = URL(fileURLWithPath: arguments[flag + 1], isDirectory: true)
        }
        isActive = arguments.contains("--demo") || exportDirectory != nil
    }
}
