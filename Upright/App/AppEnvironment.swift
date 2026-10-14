import Foundation

/// Where AppModel's side effects go: the real Mac (`.live`) or nowhere (`.demo`).
///
/// Demo Mode (`Upright --demo`, see `DemoMode` and docs/dev/DEMO-MODE-SPEC.md) runs the real UI
/// driven by simulated mice and must leave the Mac and the user's setup untouched:
/// - its own defaults suite (`DemoMode.defaultsSuiteName`), emptied at start, so the user's
///   `io.github.upright.Upright` domain is never read or written;
/// - no IOKit: DeviceManager gets a simulated link source;
/// - no event taps or event monitors: no scroll tap, no drag rewriter (it lives in the action
///   performer, which is a no-op), no cursor-movement monitor for gesture fallback;
/// - no synthetic events: button actions go to `NoOpActionPerformer`;
/// - no permission prompts: `PermissionsMonitor` reports everything granted;
/// - no login-item changes and no battery notifications.
enum AppEnvironment: Equatable, Sendable {
    case live
    case demo

    /// Decided once, from `DemoMode` (configured first thing at launch) or, if something asks
    /// before that, from the launch arguments directly.
    static let current: AppEnvironment = resolve(arguments: CommandLine.arguments)

    static func resolve(arguments: [String]) -> AppEnvironment {
        if DemoMode.isActive { return .demo }
        return arguments.contains("--demo") || arguments.contains("--export-snapshots") ? .demo : .live
    }

    var isDemo: Bool { self == .demo }

    /// Session event taps and global event monitors (scroll rewriting, the drag rewriter,
    /// cursor-movement gesture fallback).
    var usesEventTaps: Bool { self == .live }

    /// Battery notifications (and the notification-permission prompt).
    var postsNotifications: Bool { self == .live }

    /// Registering or unregistering the login item.
    var managesLoginItem: Bool { self == .live }

    /// Asking macOS for Accessibility or Input Monitoring.
    var checksPermissions: Bool { self == .live }

    /// The defaults this environment reads and writes. Demo Mode's suite is wiped every time it
    /// is created, so a demo run always starts from a fresh install.
    func makeDefaults() -> UserDefaults {
        switch self {
        case .live:
            return .standard
        case .demo:
            let name = DemoMode.defaultsSuiteName
            // Only nil for the app's own bundle ID or the global domain, which this never is.
            // Never fall back to the user's domain.
            guard let suite = UserDefaults(suiteName: name) else {
                preconditionFailure("Demo Mode needs its own defaults suite (\(name))")
            }
            suite.removePersistentDomain(forName: name)
            return suite
        }
    }
}

/// Button actions in Demo Mode: nothing is posted, launched or opened. Keeps a short history so
/// a demo UI could show what would have happened.
@MainActor
final class NoOpActionPerformer: ActionPerforming {
    struct Entry: Equatable {
        let effect: ActionEffect
        let phase: ActionPhase
        let date: Date
    }

    private(set) var history: [Entry] = []
    private static let maxHistory = 50

    func perform(_ effect: ActionEffect, phase: ActionPhase) {
        history.append(Entry(effect: effect, phase: phase, date: Date()))
        if history.count > Self.maxHistory {
            history.removeFirst(history.count - Self.maxHistory)
        }
    }
}

extension AppEnvironment {
    /// Live: Logitech interfaces from IOKit. Demo: the simulated fleet, never IOKit.
    @MainActor
    func makeDeviceManager() -> DeviceManager {
        switch self {
        case .live: return DeviceManager(source: IOKitLinkSource())
        case .demo: return DeviceManager(source: SimulatedLinkSource.demo())
        }
    }
}
