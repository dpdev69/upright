import SwiftUI

/// The Settings sidebar. `.device` is the Mice pane (every mouse, its speed and its log); the
/// case keeps its name so links to it (e.g. "Edit Presets…") keep working.
enum SettingsPane: String, CaseIterable, Identifiable {
    case buttons
    case scrolling
    case device
    case general
    case permissions
    case about

    var id: Self { self }

    var title: String {
        switch self {
        case .buttons: return String(localized: "Buttons")
        case .scrolling: return String(localized: "Scrolling")
        case .device: return String(localized: "Mice")
        case .general: return String(localized: "General")
        case .permissions: return String(localized: "Permissions")
        case .about: return String(localized: "About")
        }
    }

    var symbolName: String {
        switch self {
        case .buttons: return "computermouse.fill"
        case .scrolling: return "scroll.fill"
        case .device: return "dot.radiowaves.left.and.right"
        case .general: return "gearshape.fill"
        case .permissions: return "hand.raised.fill"
        case .about: return "info.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .buttons: return .blue
        case .scrolling: return .teal
        case .device: return .green
        case .general: return .gray
        case .permissions: return .orange
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
                .accessibilityLabel(Text(pane.title))
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 200, max: 260)
            .modifier(FixedSidebar())
        } detail: {
            detail
                .navigationTitle(model.selectedPane.title)
        }
        .frame(minWidth: 680, minHeight: 460)
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
        case .scrolling: ScrollPane()
        case .device: DevicePane()
        case .general: GeneralPane()
        case .permissions: PermissionsPane()
        case .about: AboutPane()
        }
    }
}

/// Settings windows keep their sidebar; macOS 14 lets us drop the toolbar's collapse button.
private struct FixedSidebar: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 14.0, *) {
            content.toolbar(removing: .sidebarToggle)
        } else {
            content
        }
    }
}
