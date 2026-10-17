import Foundation

/// A bidirectional channel to one HID++ capable HID interface (a receiver or a
/// directly connected device). On macOS this is backed by IOKit; tests use a simulator.
public protocol HIDPPTransport: AnyObject {
    /// Called for every input report, including the leading report ID byte.
    var onReport: (([UInt8]) -> Void)? { get set }
    /// Called once when the underlying device goes away.
    var onClose: (() -> Void)? { get set }
    /// Sends one output report. `bytes[0]` is the report ID.
    func send(_ bytes: [UInt8]) throws
}

/// What to do when macOS publishes another HID interface with the same identity.
public enum HIDInterfaceChoice: Equatable, Sendable {
    /// Open this interface.
    case use
    /// A second live interface for a mouse that is already open. Opening it interleaves HID++ replies.
    case ignore
    /// The interface we had open is gone. This one is the re-paired mouse.
    case replace
}

public enum HIDInterfaceChoicePolicy {
    /// `previousStillPresent` is true when the interface already opened is still published.
    /// A Bluetooth re-pair keeps the serial number, but the old interface is no longer present.
    public static func choose(alreadyOpen: Bool, sameInterface: Bool, previousStillPresent: Bool) -> HIDInterfaceChoice {
        guard alreadyOpen, !sameInterface else { return .use }
        return previousStillPresent ? .ignore : .replace
    }
}

/// When to try opening an interface again after macOS refused for a reason other than
/// permission. A reconnected Bluetooth mouse is published a moment before it can be opened
/// (kIOReturnNotReady), and nothing publishes it again afterwards.
public enum HIDInterfaceOpenRetryPolicy {
    /// Opens tried after the first one fails: 0.5, 1, 2, 4 s apart, then every 8 s (about 40 s in all).
    public static let maxRetries = 8

    /// The wait before the next open after `failures` failed ones, or nil to give up.
    public static func delay(afterFailures failures: Int) -> TimeInterval? {
        guard (1...maxRetries).contains(failures) else { return nil }
        return min(0.5 * pow(2, Double(failures - 1)), 8)
    }
}

/// Runs HID callbacks on the main actor in arrival order, without a `Task` hop per report:
/// synchronously when already on the main thread (IOKit delivers on the main run loop),
/// otherwise through the serial main queue.
public enum MainActorDelivery {
    /// Carries the body across the dispatch hop. It is only ever called on the main actor.
    private struct Delivery: @unchecked Sendable {
        let body: @MainActor () -> Void
    }

    public static func run(_ body: @escaping @MainActor () -> Void) {
        if Thread.isMainThread {
            MainActor.assumeIsolated(body)
        } else {
            let delivery = Delivery(body: body)
            DispatchQueue.main.async { MainActor.assumeIsolated(delivery.body) }
        }
    }
}
