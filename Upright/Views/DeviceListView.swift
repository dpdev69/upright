import SwiftUI

/// What the Mice pane shows in its detail: a live endpoint, or a mouse seen before that isn't here.
enum DeviceListSelection: Hashable {
    case live(DeviceAddress)
    case remembered(DeviceID)
}

/// A mouse seen before that isn't connected now (from `DevicePreferencesStore`).
struct RememberedDevice: Identifiable, Hashable {
    let id: DeviceID
    let preferences: DevicePreferences
    /// Nickname, else the catalog's model name, else the name it reported; numbered like live mice.
    var displayName: String

    var model: ModelKey? { preferences.lastModel ?? id.model }

    var connection: ConnectionKind? {
        preferences.lastConnection.flatMap(ConnectionKind.init(rawValue:))
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter
    }()

    /// "Last seen 3 days ago", or "Not connected" when it never was.
    var lastSeenText: String {
        guard let date = preferences.lastSeen else { return String(localized: "Not connected") }
        let relative = Self.relativeFormatter.localizedString(for: date, relativeTo: Date())
        return String(localized: "Last seen \(relative)", comment: "When a remembered mouse was last connected, e.g. Last seen 3 days ago")
    }

    /// Remembered mice in the store, most recently seen first, minus the units in `live`.
    /// Names that repeat a live or earlier name get " #2", " #3"….
    static func list(store: DevicePreferencesStore, live records: [DeviceRegistry.Record]) -> [RememberedDevice] {
        let connected = Set(records.compactMap(\.deviceID))
        var counts: [String: Int] = [:]
        for record in records where record.role != .unsupported && !record.isStandby {
            counts[baseName(of: record.displayName), default: 0] += 1
        }
        return store.rememberedDevices(excluding: connected).map { entry in
            let base = entry.preferences.trimmedNickname
                ?? (entry.preferences.lastModel ?? entry.id.model).flatMap { DeviceCatalog.model($0)?.name }
                ?? entry.preferences.lastName.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
                ?? String(localized: "Logitech mouse")
            let number = counts[base, default: 0] + 1
            counts[base] = number
            let name = number == 1 ? base : String(localized: "\(base) #\(number)", comment: "A second mouse with the same name")
            return RememberedDevice(id: entry.id, preferences: entry.preferences, displayName: name)
        }
    }

    /// The registry's numbered name without its " #n".
    private static func baseName(of name: String) -> String {
        guard let range = name.range(of: " #", options: .backwards),
              Int(name[range.upperBound...]) != nil
        else { return name }
        return String(name[..<range.lowerBound])
    }
}

/// The Mice pane's list: connected mice (in first-seen order), then mice seen before, then a
/// collapsed list of other Logitech devices Upright found but can't configure, with the reason.
///
/// Rendered as rows inside the pane's `Form`. Standby endpoints (a second link to a mouse that
/// is already listed) are folded into that mouse's row.
struct DeviceListView: View {
    let records: [DeviceRegistry.Record]
    let remembered: [RememberedDevice]
    @Binding var selection: DeviceListSelection?

    @State private var showsOtherDevices = false

    var body: some View {
        let pointers = records.filter { $0.role != .unsupported && !$0.isStandby }
        let others = records.filter { $0.role == .unsupported }

        Section {
            if pointers.isEmpty && remembered.isEmpty {
                Text("No mice yet. Connected Logitech mice appear here.")
                    .foregroundStyle(.secondary)
            }
            ForEach(Array(pointers.enumerated()), id: \.element.address) { index, record in
                row(selection: .live(record.address)) {
                    LiveDeviceRow(record: record, standbyLinks: standbyLinks(of: record))
                }
                .snapshotAnchor("device.\(index + 1)")
            }
        } header: {
            Text("Connected")
        }

        if !remembered.isEmpty {
            Section {
                ForEach(Array(remembered.enumerated()), id: \.element.id) { index, device in
                    row(selection: .remembered(device.id)) {
                        RememberedDeviceRow(device: device)
                    }
                    .snapshotAnchor("device.\(pointers.count + index + 1)")
                }
            } header: {
                Text("Not Connected")
            } footer: {
                Text("Upright keeps each mouse’s name, pointer speed and remapping switch for when it comes back.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }

        if !others.isEmpty {
            Section {
                DisclosureGroup(isExpanded: $showsOtherDevices) {
                    ForEach(others) { record in
                        row(selection: .live(record.address)) {
                            UnsupportedDeviceRow(record: record)
                        }
                    }
                } label: {
                    Text("Other Logitech devices (\(others.count))")
                        .foregroundStyle(.secondary)
                }
            } footer: {
                Text("Upright found these but can’t configure them. They keep working as usual.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func standbyLinks(of record: DeviceRegistry.Record) -> [DeviceRegistry.Record] {
        records.filter { $0.role == .standby(of: record.address) }
    }

    private func row<Content: View>(selection value: DeviceListSelection, @ViewBuilder content: () -> Content) -> some View {
        let isSelected = selection == value
        return Button {
            selection = value
        } label: {
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, 3)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.accentColor.opacity(isSelected ? 0.16 : 0))
        )
        .padding(.horizontal, -6)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

/// A connected (or connecting, asleep, failing) mouse: name, connection, state, battery.
private struct LiveDeviceRow: View {
    let record: DeviceRegistry.Record
    let standbyLinks: [DeviceRegistry.Record]

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: record.snapshot == nil ? "computermouse" : "computermouse.fill")
                .font(.title3)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.tint)
                .frame(width: 26)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: record.displayName)
                    .lineLimit(1)
                HStack(spacing: 5) {
                    StatusDot(indicator: record.indicator)
                    Image(systemName: record.connection.symbolName)
                        .accessibilityHidden(true)
                    Text(verbatim: subtitle)
                        .lineLimit(1)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if let battery = record.snapshot?.battery {
                BatteryLabel(battery: battery)
                    .font(.callout)
                    .opacity(record.isConnected ? 1 : 0.6)
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// "Bolt · Connected", plus "also on USB" for a second link to the same mouse.
    private var subtitle: String {
        var parts = [record.connection.compactTitle, record.stateText]
        if !standbyLinks.isEmpty {
            let links = ListFormatter.localizedString(byJoining: standbyLinks.map(\.connection.compactTitle))
            parts.append(String(localized: "also on \(links)", comment: "The same mouse is also connected another way, e.g. also on USB"))
        }
        return parts.joined(separator: " · ")
    }
}

private struct RememberedDeviceRow: View {
    let device: RememberedDevice

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "computermouse")
                .font(.title3)
                .foregroundStyle(.tertiary)
                .frame(width: 26)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: device.displayName)
                    .lineLimit(1)
                HStack(spacing: 5) {
                    StatusDot(indicator: .idle)
                    if let connection = device.connection {
                        Image(systemName: connection.symbolName)
                            .accessibilityHidden(true)
                    }
                    Text(verbatim: device.lastSeenText)
                        .lineLimit(1)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct UnsupportedDeviceRow: View {
    let record: DeviceRegistry.Record

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: record.unsupportedReason.map(Self.symbol(for:)) ?? "questionmark.circle")
                .font(.title3)
                .foregroundStyle(.tertiary)
                .frame(width: 26)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: record.displayName)
                    .lineLimit(1)
                Text(verbatim: [record.connection.compactTitle, record.unsupportedReason?.message ?? record.stateText].joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
        }
        .accessibilityElement(children: .combine)
    }

    private static func symbol(for reason: UnsupportedReason) -> String {
        if case .notAPointer(.keyboard) = reason { return "keyboard" }
        return "computermouse"
    }
}
