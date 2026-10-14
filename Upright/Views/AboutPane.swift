import AppKit
import SwiftUI

struct AboutPane: View {
    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return String(localized: "Version \(short) (\(build))")
    }

    var body: some View {
        Form {
            Section {
                VStack(spacing: 10) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 96, height: 96)
                        .accessibilityHidden(true)
                    Text("Upright")
                        .font(.largeTitle.weight(.semibold))
                    Text(version)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    Text("Remaps Logitech mice over HID++. Built and tested on the MX Vertical.")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .accessibilityElement(children: .combine)
            }

            Section {
                Text("Upright talks to your mouse with the publicly documented HID++ 2.0 protocol, using temporary button diversion from the REPROG_CONTROLS_V4 feature (0x1B04). It does not include or depend on any Logitech software.")
                    .fixedSize(horizontal: false, vertical: true)
                link("Solaar", "https://github.com/pwr-Solaar/Solaar")
                link("LogiOps", "https://github.com/PixlOne/logiops")
                link("libratbag", "https://github.com/libratbag/libratbag")
                link("Linux hid-logitech-hidpp driver", "https://github.com/torvalds/linux/blob/master/drivers/hid/hid-logitech-hidpp.c")
            } header: {
                Text("Built on public HID++ knowledge")
            }

            Section {
                Text("Released under the MIT License. Logitech, MX, Unifying, Bolt, Logi Options+ and other Logitech product names are trademarks of Logitech. Upright is not affiliated with or endorsed by Logitech.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
    }

    private func link(_ title: LocalizedStringKey, _ url: String) -> some View {
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
