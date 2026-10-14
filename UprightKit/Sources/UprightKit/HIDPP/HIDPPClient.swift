import Foundation

/// Request/response multiplexer on top of a `HIDPPTransport`.
///
/// Replies are matched to outstanding requests by device index, sub-ID and address (see
/// `HIDPPMessage.match(to:)`). Anything that doesn't answer a pending request — button
/// events, receiver notifications, battery broadcasts — goes to `onUnsolicited`.
///
/// Requests pass a gate (D10): at most `maxInFlight` wait for their reply at once, the rest
/// queue in FIFO order. A bare client doesn't limit them; `HIDPPLink` sets the limit from
/// `ControllerTuning.maxInFlight` (1). `Lane.interactive` requests (button diversion, pointer speed) go ahead
/// of `Lane.background` ones (probing, feature tables, battery, device information), so a
/// sleeping receiver slot delays another slot's diversion by at most one request timeout.
/// Fire-and-forget reports (`sendWithoutReply`) bypass the gate.
public final class HIDPPClient: @unchecked Sendable {
    public enum Direction: Sendable { case outgoing, incoming }

    /// The gate's priority lanes.
    public enum Lane: Hashable, Sendable {
        /// Changes the user is waiting for: setCidReporting, pointer speed.
        case interactive
        /// Everything else: probing, feature tables, battery and device information.
        case background
    }

    /// The lane for requests sent from the current task without an explicit lane.
    /// Set it for a whole operation with `HIDPPClient.$lane.withValue(.interactive) { ... }`.
    @TaskLocal public static var lane: Lane = .background

    public let transport: HIDPPTransport
    /// Identifies our requests so replies can be told apart from device events (which use 0).
    public let softwareID: UInt8 = 0x0A
    public var defaultTimeout: TimeInterval = 2.0
    /// How often a request the device answered with "busy" is sent again.
    public var busyRetryLimit = 2
    public var busyRetryDelay: TimeInterval = 0.05
    /// Requests waiting for their reply at once (at least 1). Unlimited by default; hubs use 1
    /// until hardware shows that receivers accept concurrent requests to different slots.
    public var maxInFlight: Int {
        get { gate.limit }
        set { gate.limit = newValue }
    }

    /// Invoked on the transport's delivery thread.
    public var onUnsolicited: ((HIDPPMessage) -> Void)?
    /// Invoked on the transport's delivery thread for every report in either direction.
    public var onTraffic: ((Direction, [UInt8]) -> Void)?
    public var onClose: (() -> Void)?

    private struct Pending {
        let request: HIDPPMessage
        let continuation: CheckedContinuation<HIDPPMessage, Error>
        /// Fails the request after its timeout; cancelled once the request finishes otherwise.
        let timeout: DispatchWorkItem
    }

    private let lock = NSLock()
    private var pending: [UUID: Pending] = [:]
    private var order: [UUID] = []
    private var closed = false
    private let gate = RequestGate()

    public init(transport: HIDPPTransport) {
        self.transport = transport
        transport.onReport = { [weak self] bytes in self?.receive(bytes) }
        transport.onClose = { [weak self] in self?.close() }
    }

    /// Sends `request` and waits for the matching reply. Busy errors are retried a few times.
    /// `lane` defaults to the task's `HIDPPClient.lane`. The timeout counts from when the
    /// request leaves the gate, not from when it was queued.
    public func send(_ request: HIDPPMessage, timeout: TimeInterval? = nil, lane: Lane? = nil) async throws -> HIDPPMessage {
        let lane = lane ?? Self.lane
        var attempt = 0
        while true {
            do {
                try await gate.acquire(lane)
                defer { gate.release() }
                return try await sendOnce(request, timeout: timeout)
            } catch let error as HIDPPError where error.isBusy && attempt < busyRetryLimit {
                attempt += 1
                try? await Task.sleep(nanoseconds: UInt64(max(0, busyRetryDelay) * 1_000_000_000))
            }
        }
    }

    public var isClosed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return closed
    }

    private func sendOnce(_ request: HIDPPMessage, timeout: TimeInterval?) async throws -> HIDPPMessage {
        let id = UUID()
        return try await withCheckedThrowingContinuation { continuation in
            let timeoutItem = DispatchWorkItem { [weak self] in
                self?.finish(id, with: .failure(HIDPPError.timeout))
            }
            lock.lock()
            if closed {
                lock.unlock()
                continuation.resume(throwing: HIDPPError.transportClosed)
                return
            }
            pending[id] = Pending(request: request, continuation: continuation, timeout: timeoutItem)
            order.append(id)
            lock.unlock()

            onTraffic?(.outgoing, request.bytes)
            do {
                try transport.send(request.bytes)
            } catch {
                finish(id, with: .failure(error))
                return
            }
            // A reply that already arrived has cancelled the item, so it never runs.
            DispatchQueue.global().asyncAfter(deadline: .now() + (timeout ?? defaultTimeout), execute: timeoutItem)
        }
    }

    /// Sends a report without waiting for a reply (used while the app is quitting).
    public func sendWithoutReply(_ message: HIDPPMessage) {
        onTraffic?(.outgoing, message.bytes)
        try? transport.send(message.bytes)
    }

    /// Calls a HID++ 2.0 function and returns the reply's parameter bytes.
    public func call(
        deviceIndex: UInt8,
        featureIndex: UInt8,
        function: UInt8,
        parameters: [UInt8] = [],
        timeout: TimeInterval? = nil,
        lane: Lane? = nil
    ) async throws -> [UInt8] {
        let request = HIDPPMessage.request(
            deviceIndex: deviceIndex,
            featureIndex: featureIndex,
            function: function,
            softwareID: softwareID,
            parameters: parameters
        )
        return try await send(request, timeout: timeout, lane: lane).parameters
    }

    /// Fails every pending request; further requests fail immediately.
    public func close() {
        lock.lock()
        guard !closed else { lock.unlock(); return }
        closed = true
        let all = pending.values
        pending.removeAll()
        order.removeAll()
        lock.unlock()
        gate.close()
        all.forEach {
            $0.timeout.cancel()
            $0.continuation.resume(throwing: HIDPPError.transportClosed)
        }
        onClose?()
    }

    private func receive(_ bytes: [UInt8]) {
        onTraffic?(.incoming, bytes)
        guard let message = HIDPPMessage(bytes: bytes) else { return }

        lock.lock()
        var matched: (UUID, Pending, HIDPPMessage.ResponseMatch)?
        for id in order {
            guard let candidate = pending[id], let match = message.match(to: candidate.request) else { continue }
            matched = (id, candidate, match)
            break
        }
        if let (id, _, _) = matched {
            pending[id] = nil
            order.removeAll { $0 == id }
        }
        lock.unlock()

        guard let (_, request, match) = matched else {
            onUnsolicited?(message)
            return
        }
        request.timeout.cancel()
        switch match {
        case .success: request.continuation.resume(returning: message)
        case .hidpp10Error(let code): request.continuation.resume(throwing: HIDPPError.hidpp10(code))
        case .hidpp20Error(let code): request.continuation.resume(throwing: HIDPPError.hidpp20(code))
        }
    }

    private func finish(_ id: UUID, with result: Result<HIDPPMessage, Error>) {
        lock.lock()
        let entry = pending.removeValue(forKey: id)
        order.removeAll { $0 == id }
        lock.unlock()
        entry?.timeout.cancel()
        entry?.continuation.resume(with: result)
    }
}

/// Admits at most `limit` requests at once; the others wait, interactive ones first, each lane
/// in FIFO order. A released slot is handed straight to the next waiter.
private final class RequestGate: @unchecked Sendable {
    private let lock = NSLock()
    private var inFlight = 0
    private var _limit = Int.max
    private var interactive: [CheckedContinuation<Void, Error>] = []
    private var background: [CheckedContinuation<Void, Error>] = []
    private var closed = false

    var limit: Int {
        get { lock.lock(); defer { lock.unlock() }; return _limit }
        set {
            lock.lock()
            _limit = max(1, newValue)
            var admitted: [CheckedContinuation<Void, Error>] = []
            while inFlight < _limit, let next = popWaiter() {
                inFlight += 1
                admitted.append(next)
            }
            lock.unlock()
            admitted.forEach { $0.resume() }
        }
    }

    /// Waits for a slot. Throws `transportClosed` once closed, and `CancellationError` when the
    /// task was cancelled while it waited (the slot is given back).
    func acquire(_ lane: HIDPPClient.Lane) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            lock.lock()
            if closed {
                lock.unlock()
                continuation.resume(throwing: HIDPPError.transportClosed)
                return
            }
            if inFlight < _limit, interactive.isEmpty, background.isEmpty {
                inFlight += 1
                lock.unlock()
                continuation.resume()
                return
            }
            switch lane {
            case .interactive: interactive.append(continuation)
            case .background: background.append(continuation)
            }
            lock.unlock()
        }
        if Task.isCancelled {
            release()
            throw CancellationError()
        }
    }

    func release() {
        lock.lock()
        if let next = popWaiter() {
            lock.unlock()
            next.resume()
            return
        }
        inFlight = max(0, inFlight - 1)
        lock.unlock()
    }

    func close() {
        lock.lock()
        closed = true
        let waiting = interactive + background
        interactive.removeAll()
        background.removeAll()
        lock.unlock()
        waiting.forEach { $0.resume(throwing: HIDPPError.transportClosed) }
    }

    /// Requires `lock`.
    private func popWaiter() -> CheckedContinuation<Void, Error>? {
        if !interactive.isEmpty { return interactive.removeFirst() }
        if !background.isEmpty { return background.removeFirst() }
        return nil
    }
}
