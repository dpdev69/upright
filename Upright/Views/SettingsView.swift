import SwiftUI

enum SettingsPane: String, CaseIterable, Identifiable {
    case buttons
    case general
    case permissions
    case device
    case about

    var id: Self { self }

    var title: String {
        switch self {
        case .buttons: return "Buttons"
        case .general: return "General"
        case .permissions: return "Permissions"
        case .device: return "Device"
        case .about: return "About"
        }
    }

    var symbolName: String {
        switch self {
        case .buttons: return "computermouse.fill"
        case .general: return "gearshape.fill"
        case .permissions: return "hand.raised.fill"
        case .device: return "waveform.path.ecg"
        case .about: return "info.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .buttons: return .blue
        case .general: return .gray
        case .permissions: return .orange
        case .device: return .green
        case .about: return .indigo
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        NavigationSplitView {
            List(SettingsPane.allCases, selection: selection) { pane in
                Label {
                    Text(pane.title)
                } icon: {
                    SymbolTile(systemName: pane.symbolName, color: pane.tint, size: 22)
                }
                .padding(.vertical, 2)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 240)
        } detail: {
            detail
                .navigationTitle(model.selectedPane.title)
        }
        .frame(minWidth: 700, minHeight: 480)
    }

    private var selection: Binding<SettingsPane?> {
        Binding(
            get: { model.selectedPane },
            set: { if let pane = $0 { model.selectedPane = pane } }
        )
    }

    @ViewBuilder
    private var detail: some View {
        switch model.selectedPane {
        case .buttons: ButtonsPane()
        case .general: GeneralPane()
        case .permissions: PermissionsPane()
        case .device: DevicePane()
        case .about: AboutPane()
        }
    }
}
