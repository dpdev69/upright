import SwiftUI

/// Named view bounds collected for the snapshot manifest.
struct SnapshotAnchorKey: PreferenceKey {
    static var defaultValue: [String: Anchor<CGRect>] { [:] }

    static func reduce(value: inout [String: Anchor<CGRect>], nextValue: () -> [String: Anchor<CGRect>]) {
        value.merge(nextValue()) { _, new in new }
    }
}

extension View {
    /// Names this view's bounds in the snapshot manifest (`rects` in manifest.json). A no-op
    /// unless Demo Mode is exporting snapshots.
    ///
    /// The bounds travel two ways: as an anchor preference (`SnapshotAnchorKey`), which the
    /// exporter resolves against its root view, and as a window-space frame reported to
    /// `SnapshotAnchorCollector`. The second covers views that AppKit hosts on their own (rows of
    /// a `Form` or `List` live in table cells, whose preferences don't reach the root).
    @ViewBuilder
    func snapshotAnchor(_ name: String) -> some View {
        if DemoMode.isExporting {
            transformAnchorPreference(key: SnapshotAnchorKey.self, value: .bounds) { value, anchor in
                value[name] = anchor
            }
            .background(SnapshotFrameReporter(name: name))
        } else {
            self
        }
    }
}

/// The window-space frames of every `snapshotAnchor` on screen, by name (points, top-left origin
/// of the window's content). Only filled while exporting. `reset()` starts a new capture: views
/// of an earlier one that report late are ignored.
@MainActor
final class SnapshotAnchorCollector {
    static let shared = SnapshotAnchorCollector()

    /// Frames by name. Views that left the hierarchy are removed.
    private(set) var frames: [String: CGRect] = [:]
    /// How many views report each name right now (a name can appear twice during an update).
    private var counts: [String: Int] = [:]
    private(set) var generation = 0

    func reset() {
        generation += 1
        frames.removeAll()
        counts.removeAll()
    }

    fileprivate func appeared(_ name: String, frame: CGRect) -> Int {
        counts[name, default: 0] += 1
        frames[name] = frame
        return generation
    }

    fileprivate func moved(_ name: String, frame: CGRect, generation: Int?) {
        guard generation == self.generation else { return }
        frames[name] = frame
    }

    fileprivate func disappeared(_ name: String, generation: Int?) {
        guard generation == self.generation else { return }
        let remaining = (counts[name] ?? 1) - 1
        if remaining <= 0 {
            counts[name] = nil
            frames[name] = nil
        } else {
            counts[name] = remaining
        }
    }
}

private struct SnapshotFrameReporter: View {
    let name: String
    @State private var generation: Int?

    var body: some View {
        GeometryReader { proxy in
            let frame = proxy.frame(in: .global)
            Color.clear
                .onAppear { generation = SnapshotAnchorCollector.shared.appeared(name, frame: frame) }
                .onChange(of: frame) { SnapshotAnchorCollector.shared.moved(name, frame: $0, generation: generation) }
                .onDisappear { SnapshotAnchorCollector.shared.disappeared(name, generation: generation) }
        }
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }
}
