import SwiftUI

/// The Mice pane's list of devices.
///
/// Wave 0 scaffold: W5.1 owns this file (sections for connected, remembered and unsupported
/// devices; connection glyphs, battery, state; duplicate-name numbering).
struct DeviceListView: View {
    let records: [DeviceRegistry.Record]
    @Binding var selection: DeviceAddress?

    var body: some View {
        List(records, selection: $selection) { record in
            Text(verbatim: record.displayName)
        }
    }
}
