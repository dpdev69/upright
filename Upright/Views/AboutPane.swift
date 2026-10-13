import SwiftUI

struct AboutPane: View {
    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return "Version \(short) (\(build))"
    }

    var body: some View {
        Form {
            Section {
                VStack(spacing: 10) {
                    SymbolTile(systemName: "computermouse.fill", color: .blue, size: 72)
                    Text("Upright")
                        .font(.largeTitle.weight(.semibold))
                    Text(version)
                        .foregroundStyle(.secondary)
                    Text("Open-source button remapping for the Logitech MX Vertical, without Logi Options+.")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            }

            Section {
                Text("Upright talks to the mouse with the publicly documented HID++ 2.0 protocol, using temporary button diversion from the REPROG_CONTROLS_V4 feature (0x1B04). It does not include or depend on any Logitech software.")
                    .fixedSize(horizontal: false, vertical: true)
                link("Solaar", "https://github.com/pwr-Solaar/Solaar")
                link("LogiOps", "https://github.com/PixlOne/logiops")
                link("libratbag", "https://github.com/libratbag/libratbag")
                link("Linux hid-logitech-hidpp driver", "https://github.com/torvalds/linux/blob/master/drivers/hid/hid-logitech-hidpp.c")
            } header: {
                Text("Built on public HID++ knowledge")
            }

            Section {
                Text("Released under the MIT License. Logitech, MX Vertical, Unifying, Bolt and Logi Options+ are trademarks of Logitech. Upright is not affiliated with or endorsed by Logitech.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
    }

    private func link(_ title: String, _ url: String) -> some View {
        Link(destination: URL(string: url)!) {
            HStack {
                Text(title)
                Spacer()
                Image(systemName: "arrow.up.right.square")
                    .foregroundStyle(.secondary)
            }
        }
    }
}
