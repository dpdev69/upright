import Foundation

/// Renders the essential UI states offscreen in light and dark, and writes `<id>.<appearance>.png`
/// files plus `manifest.json` (sizes and `snapshotAnchor` rects) to a directory.
///
/// Wave 0 scaffold: W5.5 owns this file and implements it.
@MainActor
enum SnapshotExporter {
    enum ExportError: Error, CustomStringConvertible {
        case notImplemented

        var description: String {
            switch self {
            case .notImplemented: return "Snapshot export is not available in this build."
            }
        }
    }

    static func run(model: AppModel, to directory: URL) async throws {
        throw ExportError.notImplemented
    }
}
