import Foundation
import XCTest
@testable import UprightKit

// Shared helpers for tests that drive hubs, controllers and the simulator. They are free
// functions on purpose: a test class may still declare private helpers with the same names
// (those win inside the class), and declarations in an XCTestCase extension couldn't be
// redeclared by subclasses.

extension ControllerTuning {
    /// Short timeouts and no reconnect delay, so controller tests finish quickly.
    static var fastTests: ControllerTuning {
        var tuning = ControllerTuning()
        tuning.probeTimeout = 0.2
        tuning.reconnectDelay = 0
        tuning.retryBaseDelay = 0.05
        tuning.retryMaxDelay = 0.2
        tuning.retryMaxDelayWithNotifications = 0.2
        tuning.announcementWait = 0.05
        return tuning
    }
}

/// A hub on `transport` with `ControllerTuning.fastTests`.
@MainActor
func makeLink(
    _ transport: HIDPPTransport,
    kind: TransportKind,
    link: UInt32 = 1,
    tuning: ControllerTuning = .fastTests
) -> HIDPPLink {
    HIDPPLink(transport: transport, kind: kind, link: link, tuning: tuning)
}

/// A hub on a simulated receiver or direct link, with the matching transport kind.
@MainActor
func makeLink(_ simulator: SimulatedHIDPPTransport, link: UInt32 = 1, tuning: ControllerTuning = .fastTests) -> HIDPPLink {
    makeLink(simulator, kind: simulator.transportKind, link: link, tuning: tuning)
}

/// Polls `condition` every 10 ms until it holds, failing the test after `timeout`.
@MainActor
func eventually(
    _ description: String,
    timeout: TimeInterval = 3,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ condition: () -> Bool
) async {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        if Date() > deadline {
            XCTFail("Timed out waiting for: \(description)", file: file, line: line)
            return
        }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
}

func pause(_ seconds: TimeInterval) async {
    try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
}

/// Whether the endpoint at `index` on `link` is connected.
@MainActor
func isConnected(_ link: HIDPPLink, at index: UInt8) -> Bool {
    if case .connected = link.endpoints[index]?.state { return true }
    return false
}

/// Whether the endpoint at `index` on `link` is asleep (found, but not answering).
@MainActor
func isAsleep(_ link: HIDPPLink, at index: UInt8) -> Bool {
    if case .asleep = link.endpoints[index]?.state { return true }
    return false
}

/// Collects values delivered to a callback, for later assertions.
final class Recorder<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Value] = []

    init() {}

    func append(_ value: Value) {
        lock.lock()
        values.append(value)
        lock.unlock()
    }

    /// Everything appended so far, in order.
    var records: [Value] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }

    var count: Int { records.count }

    func removeAll() {
        lock.lock()
        values.removeAll()
        lock.unlock()
    }
}
