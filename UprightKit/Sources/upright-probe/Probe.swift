import Foundation
import UprightKit

#if canImport(IOKit)
import IOKit.hid

@main
struct Probe {
    @MainActor
    static func main() {
        let arguments = Set(CommandLine.arguments.dropFirst())
        if arguments.contains("-h") || arguments.contains("--help") {
            print("""
            usage: upright-probe [--divert]

            Finds a Logitech MX Vertical (USB cable, Unifying/Bolt receiver, or Bluetooth),
            prints its HID++ 2.0 feature table and REPROG_CONTROLS_V4 control list, then keeps
            listening for receiver and device notifications.

              --divert   Temporarily divert every remappable button and print press/release
                         events. Buttons return to normal when you press Ctrl-C.
            """)
            return
        }

        let session = ProbeSession(divertAll: arguments.contains("--divert"))
        session.start()

        signal(SIGINT, SIG_IGN)
        let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        interrupt.setEventHandler {
            Task { @MainActor in
                session.shutdown()
                print("\nRestored default button behavior.")
                exit(0)
            }
        }
        interrupt.resume()

        withExtendedLifetime((session, interrupt)) {
            RunLoop.main.run()
        }
    }
}

@MainActor
final class ProbeSession {
    private let divertAll: Bool
    private let monitor = HIDDeviceMonitor()
    private var entries: [IOHIDDevice: (transport: IOKitHIDTransport, controller: MXVerticalController)] = [:]

    init(divertAll: Bool) {
        self.divertAll = divertAll
    }

    func start() {
        monitor.onMatch = { [weak self] device in
            Task { @MainActor in self?.attach(device) }
        }
        monitor.onRemove = { [weak self] device in
            Task { @MainActor in self?.detach(device) }
        }
        let result = monitor.start()
        print(String(format: "Watching for Logitech HID++ interfaces (IOHIDManagerOpen: 0x%08X)", UInt32(bitPattern: result)))
        print("Input Monitoring access: \(Self.describe(HIDDeviceMonitor.inputMonitoringAccess))")
    }

    func shutdown() {
        entries.values.forEach { $0.controller.shutdown() }
    }

    private func attach(_ device: IOHIDDevice) {
        let info = HIDDeviceMonitor.info(for: device)
        guard let kind = MXVertical.classify(vendorID: info.vendorID, productID: info.productID) else {
            print("· Ignoring \(info.summary)")
            return
        }
        print("→ Found \(info.summary)")

        let transport = IOKitHIDTransport(device: device)
        do {
            try transport.open()
        } catch {
            print("  ✗ \(error)")
            return
        }

        let controller = MXVerticalController(transport: transport, kind: kind)
        controller.onLog = { print("  \($0)") }
        controller.client.onTraffic = { direction, bytes in
            let arrow = direction == .outgoing ? ">>" : "<<"
            print("    \(arrow) " + bytes.prefix(20).map { String(format: "%02X", $0) }.joined(separator: " "))
        }
        controller.onButtonEvent = { event in
            let name = ControlDescriptor(cid: event.cid).name
            print("  ● \(name) (\(String(format: "0x%04X", event.cid))) \(event.phase == .press ? "pressed" : "released")")
        }
        controller.onStateChange = { [weak self, weak controller] state in
            guard let self, let controller else { return }
            self.report(state, controller: controller)
        }
        entries[device] = (transport, controller)
        controller.start()
    }

    private func detach(_ device: IOHIDDevice) {
        guard let entry = entries.removeValue(forKey: device) else { return }
        entry.controller.shutdown()
        entry.transport.deviceRemoved()
        print("← \(entry.transport.info.product) removed")
    }

    private func report(_ state: MXVerticalController.State, controller: MXVerticalController) {
        switch state {
        case .probing:
            print("  … probing")
        case .waitingForDevice:
            print("  … receiver found, waiting for the MX Vertical to wake up (click a button)")
        case .asleep:
            print("  … mouse asleep")
        case .failed(let message):
            print("  ✗ \(message)")
        case .connected(let snapshot):
            print("""

              ✓ \(snapshot.name) over \(snapshot.connection.title), device index 0x\(String(format: "%02X", snapshot.deviceIndex)), HID++ \(snapshot.protocolVersion)
            """)
            if let battery = snapshot.battery {
                print("    Battery: \(battery.percentage)%\(battery.isCharging ? " (charging)" : "")")
            }
            print("    Features:")
            for feature in snapshot.features {
                print(String(format: "      [%02d] 0x%04X v%d  %@", feature.index, feature.featureID, feature.version, feature.name))
            }
            print("    Controls:")
            for control in snapshot.controls {
                let marker = control.isConfigurable ? "*" : " "
                print(String(format: "     %@ CID 0x%04X  TID 0x%04X  %@  [%@]", marker, control.cid, control.taskID,
                             ControlDescriptor(cid: control.cid).name, control.flags.names.joined(separator: ", ")))
            }
            print("    (* = remappable by Upright)\n")
            if divertAll {
                let all = Set(snapshot.configurableControls.map(\.cid))
                if controller.desiredDiversion != all {
                    controller.setDesiredDiversion(all)
                    print("  Diverting all remappable buttons — press them to see events. Ctrl-C to restore.\n")
                }
            }
        }
    }

    static func describe(_ access: IOHIDAccessType) -> String {
        switch access {
        case kIOHIDAccessTypeGranted: return "granted"
        case kIOHIDAccessTypeDenied: return "denied"
        default: return "not determined"
        }
    }
}

#else

@main
struct Probe {
    static func main() {
        print("upright-probe talks to HID devices through IOKit and only runs on macOS.")
    }
}

#endif
