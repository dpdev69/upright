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
    @ViewBuilder
    func snapshotAnchor(_ name: String) -> some View {
        if DemoMode.isExporting {
            transformAnchorPreference(key: SnapshotAnchorKey.self, value: .bounds) { value, anchor in
                value[name] = anchor
            }
        } else {
            self
        }
    }
}
