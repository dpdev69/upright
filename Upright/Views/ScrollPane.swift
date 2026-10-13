import SwiftUI

/// Mouse-wheel direction, speed and smoothing. Trackpads and Magic Mouse are never affected.
struct ScrollPane: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var devices: DeviceManager
    @EnvironmentObject private var permissions: PermissionsMonitor

    var body: some View {
        Form {
            if let status {
                Section {
                    status
                }
            }

            Section {
                Toggle(isOn: binding(\.reverseVertical)) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Reverse vertical scrolling")
                        Text("Turn the wheel down to move content up, independently of the trackpad’s Natural Scrolling.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Toggle(isOn: binding(\.reverseHorizontal)) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Reverse horizontal scrolling")
                        Text("Applies to tilt and Shift-scroll.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Direction")
            }

            Section {
                LabeledContent {
                    HStack(spacing: 10) {
                        Slider(value: binding(\.speed), in: ScrollSettings.speedRange, step: 0.25) {
                            Text("Scrolling speed")
                        } minimumValueLabel: {
                            Image(systemName: "tortoise").accessibilityHidden(true)
                        } maximumValueLabel: {
                            Image(systemName: "hare").accessibilityHidden(true)
                        }
                        .labelsHidden()
                        .accessibilityValue(Text(speedText))
                        Text(speedText)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(minWidth: 40, alignment: .trailing)
                            .accessibilityHidden(true)
                    }
                    .frame(maxWidth: 320)
                } label: {
                    Text("Speed")
                }

                Toggle(isOn: binding(\.smoothScrolling)) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text("Smooth scrolling")
                            ExperimentalBadge()
                        }
                        Text("Turns each wheel notch into a short, eased glide.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Feel")
            }

            Section {
                Toggle(isOn: binding(\.onlyWhileMXVerticalConnected)) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Only while the MX Vertical is connected")
                        Text("macOS doesn’t say which mouse a scroll came from. With this off, every mouse wheel is changed, but trackpads never are.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                HStack {
                    Spacer()
                    Button("Restore Defaults") { model.settings.resetScrollSettings() }
                        .disabled(model.settings.scrollSettings == .default)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var speedText: String {
        model.settings.scrollSettings.speed.formatted(.number.precision(.fractionLength(0...2))) + "×"
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<ScrollSettings, Value>) -> Binding<Value> {
        Binding(
            get: { model.settings.scrollSettings[keyPath: keyPath] },
            set: { model.settings.scrollSettings[keyPath: keyPath] = $0 }
        )
    }

    /// Why the settings aren't in effect, when they should be but aren't.
    private var status: AnyView? {
        let settings = model.settings.scrollSettings
        guard settings.transformsEvents, !model.scroll.isActive else { return nil }
        if !permissions.isAccessibilityTrusted {
            return AnyView(
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "hand.raised.fill")
                        .font(.title2)
                        .foregroundStyle(.orange)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Accessibility access needed")
                            .font(.headline)
                        Text("Upright needs Accessibility access to change scrolling. Until you allow it, scrolling works as usual.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    Button("Open Settings…") { permissions.requestAccessibility() }
                }
            )
        }
        if settings.onlyWhileMXVerticalConnected, devices.snapshot == nil {
            return AnyView(
                Label("Paused until the MX Vertical connects.", systemImage: "pause.circle")
                    .foregroundStyle(.secondary)
            )
        }
        return AnyView(
            Label("Upright couldn’t start changing scrolling. Try turning a setting off and on again.", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
        )
    }
}

struct ExperimentalBadge: View {
    var body: some View {
        Text("Experimental")
            .font(.caption2.weight(.semibold))
            .textCase(.uppercase)
            .foregroundStyle(.orange)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Capsule().strokeBorder(.orange.opacity(0.6)))
            .accessibilityLabel(Text("Experimental"))
    }
}
