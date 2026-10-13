import Foundation
import UprightKit

// The IOKit side of upright-probe: finds Logitech HID interfaces, opens them, and hands them to
// ProbeRunner (ProbeReport.swift), which does the reading and printing.

#if canImport(IOKit)
import IOKit.hid

@main
struct Probe {
    @MainActor
    static func main() {
        let options: ProbeOptions
        do {
            options = try ProbeOptions.parse(Array(CommandLine.arguments.dropFirst()))
        } catch {
            FileHandle.standardError.write(Data("upright-probe: \(error)\n\n\(ProbeOptions.usage)\n".utf8))
            exit(2)
        }
        if options.showHelp {
            print(ProbeOptions.usage)
            return
        }

        let session = ProbeSession(options: options)
        session.start()

        // Diversion lasts only while the probe runs; hand the buttons back however it is stopped.
        var signalSources: [DispatchSourceSignal] = []
        for number in [SIGINT, SIGTERM, SIGHUP] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler {
                Task { @MainActor in
                    print()
                    session.finish()
                    exit(0)
                }
            }
            source.resume()
            signalSources.append(source)
        }

        withExtendedLifetime((session, signalSources)) {
            RunLoop.main.run()
        }
    }
}

@MainActor
final class ProbeSession {
    private struct OpenInterface {
        var transport: IOKitHIDTransport
        var info: HIDInterfaceInfo
        var link: UInt32
    }

    private let options: ProbeOptions
    private let console: ProbeConsole
    private let runner: ProbeRunner
    private let monitor = HIDDeviceMonitor()
    private var open: [IOHIDDevice: OpenInterface] = [:]
    /// Interfaces that are listed but not read (they carry no HID++, or opening them failed),
    /// so that their removal is still announced.
    private var listed: [IOHIDDevice: UInt32] = [:]
    private var nextLink: UInt32 = 1

    init(options: ProbeOptions) {
        self.options = options
        console = ProbeConsole()
        runner = ProbeRunner(options: options, console: console)
    }

    func start() {
        // Without --all the monitor keeps back what Upright ignores and reports it through onIgnored.
        monitor.deliversIgnoredInterfaces = options.all
        monitor.onMatch = { [weak self] device in
            MainActorDelivery.run { self?.attach(device) }
        }
        monitor.onRemove = { [weak self] device in
            MainActorDelivery.run { self?.detach(device, removed: true) }
        }
        monitor.onIgnored = { [weak self] info, reason in
            MainActorDelivery.run { self?.console.say("· Ignoring \(info.summary): \(reason)") }
        }
        let result = monitor.start()
        console.say(String(format: "Watching for Logitech HID++ interfaces (IOHIDManagerOpen: 0x%08X)", UInt32(bitPattern: result)))
        console.say("Input Monitoring access: \(Self.describe(HIDDeviceMonitor.inputMonitoringAccess))")
        if options.all {
            console.say("--all: interfaces Upright doesn't use are listed and read too (reads only).")
        }
        Task {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            if open.isEmpty && listed.isEmpty {
                console.say("No Logitech HID++ interface found yet. Check the cable or receiver, wake the mouse, and that Input Monitoring is allowed for your terminal.")
            }
        }
    }

    /// Hands every diverted button back and closes everything.
    func finish() {
        runner.shutdown()
        for entry in open.values { entry.transport.close() }
        open.removeAll()
        console.say(runner.hasDivertedButtons ? "Restored default button behavior." : "Stopped.")
    }

    private func attach(_ device: IOHIDDevice) {
        let hidInfo = HIDDeviceMonitor.info(for: device)
        var info = ProbeLinkInfo.make(number: 0, descriptor: hidInfo.descriptor)

        // Over USB a mouse publishes a vendor-page HID++ interface and a mouse interface, and a
        // Bluetooth mouse can appear twice. Opening both interleaves HID++ replies, so use one
        // per physical device.
        if info.carriesHIDPP {
            guard let superseded = HIDInterfaceInfo.twinsToReplace(adding: hidInfo, open: open.mapValues(\.info)) else {
                console.say("· Ignoring twin interface \(hidInfo.summary)")
                return
            }
            superseded.forEach { detach($0, removed: false) }
        }

        info.number = nextLink
        nextLink += 1
        runner.announce(info)

        guard info.carriesHIDPP else {
            listed[device] = info.number
            return
        }
        let transport = IOKitHIDTransport(device: device)
        do {
            try transport.open()
        } catch {
            var text = "✗ \(error)"
            if (error as? IOKitHIDError)?.isPermissionDenied == true {
                text += "\n    upright-probe runs inside your terminal app: allow that app under Input Monitoring."
            }
            console.say(text, link: info.number)
            listed[device] = info.number
            return
        }
        open[device] = OpenInterface(transport: transport, info: hidInfo, link: info.number)

        if let kind = info.transportKind {
            let link = HIDPPLink(
                transport: transport,
                kind: kind,
                link: info.number,
                productID: info.productID,
                productName: info.productName.isEmpty ? nil : info.productName
            )
            runner.attachHub(link, info: info)
        } else {
            let client = HIDPPClient(transport: transport)
            // One request at a time, as the app does.
            client.maxInFlight = 1
            runner.attachRaw(client: client, info: info)
        }
    }

    private func detach(_ device: IOHIDDevice, removed: Bool) {
        if let number = listed.removeValue(forKey: device) {
            console.say("← removed", link: number)
            console.removeLink(number)
            return
        }
        guard let entry = open.removeValue(forKey: device) else { return }
        if removed {
            // The hub sees the transport close and drops its endpoints (nothing to restore).
            entry.transport.deviceRemoved()
            console.say("← removed", link: entry.link)
            runner.detach(link: entry.link)
        } else {
            console.say("← closed in favor of its HID++ interface", link: entry.link)
            runner.detach(link: entry.link)
            entry.transport.close()
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
