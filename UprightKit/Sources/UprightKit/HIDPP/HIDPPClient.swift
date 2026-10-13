import Foundation

/// Request/response multiplexer on top of a `HIDPPTransport`.
///
/// Replies are matched to outstanding requests by device index, sub-ID and address (see
/// `HIDPPMessage.match(to:)`). Anything that doesn't answer a pending request — button
/// events, receiver notifications, battery broadcasts — goes to `onUnsolicited`.
public final class HIDPPClient: @unchecked Sendable {
    public enum Direction: Sendable { case outgoing, incoming }

    public let transport: HIDPPTransport
    /// Identifies our requests so replies can be told apart from device events (which use 0).
    public let softwareID: UInt8 = 0x0A
    public var defaultTimeout: TimeInterval = 2.0
    /// How often a request the device answered with "busy" is sent again.
    public var busyRetryLimit = 2
    public var busyRetryDelay: TimeInterval = 0.05

    /// Invoked on the transport's delivery thread.
    public var onUnsolicited: ((HIDPPMessage) -> Void)?
    /// Invoked on the transport's delivery thread for every report in either direction.
    public var onTraffic: ((Direction, [UInt8]) -> Void)?
    public var onClose: (() -> Void)?

    private struct Pending {
        let request: HIDPPMessage
        let continuation: CheckedContinuation<HIDPPMessage, Error>
    }

    private let lock = NSLock()
    private var pending: [UUID: Pending] = [:]
    private var order: [UUID] = []
    private var closed = false

    public init(transport: HIDPPTransport) {
        self.transport = transport
        transport.onReport = { [weak self] bytes in self?.receive(bytes) }
        transport.onClose = { [weak self] in self?.close() }
    }

    /// Sends `request` and waits for the matching reply. Busy errors are retried a few times.
    public func send(_ request: HIDPPMessage, timeout: TimeInterval? = nil) async throws -> HIDPPMessage {
        var attempt = 0
        while true {
            do {
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
            lock.lock()
            if closed {
                lock.unlock()
                continuation.resume(throwing: HIDPPError.transportClosed)
                return
            }
            pending[id] = Pending(request: request, continuation: continuation)
            order.append(id)
            lock.unlock()

            onTraffic?(.outgoing, request.bytes)
            do {
                try transport.send(request.bytes)
            } catch {
                finish(id, with: .failure(error))
                return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + (timeout ?? defaultTimeout)) { [weak self] in
                self?.finish(id, with: .failure(HIDPPError.timeout))
            }
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
        timeout: TimeInterval? = nil
    ) async throws -> [UInt8] {
        let request = HIDPPMessage.request(
            deviceIndex: deviceIndex,
            featureIndex: featureIndex,
            function: function,
            softwareID: softwareID,
            parameters: parameters
        )
        return try await send(request, timeout: timeout).parameters
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
        all.forEach { $0.continuation.resume(throwing: HIDPPError.transportClosed) }
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
        entry?.continuation.resume(with: result)
    }
}
