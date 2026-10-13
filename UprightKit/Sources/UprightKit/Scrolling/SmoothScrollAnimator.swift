import Foundation

/// Experimental smooth scrolling: spreads each wheel notch's distance over a short ease-out
/// curve, emitted as whole-pixel frames. Notches that arrive mid-animation add to what is left.
/// Pure timing math; the caller supplies the clock and posts the frames.
public struct SmoothScrollAnimator: Sendable {
    public enum Phase: Hashable, Sendable {
        case began, changed, ended
    }

    public struct Frame: Hashable, Sendable {
        public var vertical: Int32
        public var horizontal: Int32
        public var phase: Phase
    }

    /// Pixels one line of wheel travel scrolls. Browsers use about 40 per notch, Cocoa scroll views 10.
    public static let pixelsPerLine = 32.0

    /// The pixel distance for one wheel event's (already transformed) delta. Prefers the
    /// fractional line delta, which carries macOS's wheel acceleration.
    public static func distance(lines: Int64, fixedPtLines: Double) -> Double {
        (fixedPtLines != 0 ? fixedPtLines : Double(lines)) * pixelsPerLine
    }

    public var duration: TimeInterval

    private enum State: Sendable {
        case idle
        case moving(hasBegun: Bool)
        /// The distance is fully emitted; one `.ended` frame is still owed.
        case ending
    }

    private var state = State.idle
    private var start: TimeInterval = 0
    private var distance1 = 0.0
    private var distance2 = 0.0
    /// Eased progress already emitted for the current segment.
    private var emittedProgress = 0.0
    private var carry1 = 0.0
    private var carry2 = 0.0

    public init(duration: TimeInterval = 0.18) {
        self.duration = max(duration, 0.01)
    }

    /// True while frames remain, including the closing `.ended` frame.
    public var isActive: Bool {
        if case .idle = state { return false }
        return true
    }

    /// Adds a notch's distance in pixels. What is left of the current animation in the same
    /// direction is kept; the opposite direction is dropped.
    public mutating func add(vertical: Double, horizontal: Double, at now: TimeInterval) {
        guard vertical != 0 || horizontal != 0 else { return }
        let remaining = 1 - Self.ease(emittedProgress)
        let hasBegun: Bool
        switch state {
        case .idle:
            distance1 = 0
            distance2 = 0
            carry1 = 0
            carry2 = 0
            hasBegun = false
        case .moving(let begun):
            hasBegun = begun
        case .ending:
            hasBegun = true
        }
        distance1 = Self.combine(left: distance1 * remaining, added: vertical, carry: &carry1)
        distance2 = Self.combine(left: distance2 * remaining, added: horizontal, carry: &carry2)
        start = now
        emittedProgress = 0
        state = .moving(hasBegun: hasBegun)
    }

    /// The next frame, or nil when idle.
    public mutating func step(at now: TimeInterval) -> Frame? {
        switch state {
        case .idle:
            return nil
        case .ending:
            state = .idle
            return Frame(vertical: 0, horizontal: 0, phase: .ended)
        case .moving(let hasBegun):
            let progress = min(max((now - start) / duration, 0), 1)
            let eased = Self.ease(progress)
            let fraction = eased - Self.ease(emittedProgress)
            emittedProgress = progress
            let done = progress >= 1
            let v = Self.take(distance1 * fraction, carry: &carry1, final: done)
            let h = Self.take(distance2 * fraction, carry: &carry2, final: done)
            state = done ? .ending : .moving(hasBegun: true)
            return Frame(vertical: v, horizontal: h, phase: hasBegun ? .changed : .began)
        }
    }

    public mutating func cancel() {
        state = .idle
        emittedProgress = 0
    }

    /// Ease-out cubic: fast start so the first frame responds right away.
    static func ease(_ t: Double) -> Double {
        let inverse = 1 - t
        return 1 - inverse * inverse * inverse
    }

    private static func combine(left: Double, added: Double, carry: inout Double) -> Double {
        if added != 0, left != 0, (left > 0) != (added > 0) {
            carry = 0
            return added
        }
        return left + added
    }

    private static func take(_ amount: Double, carry: inout Double, final: Bool) -> Int32 {
        let exact = amount + carry
        let whole = final ? exact.rounded() : exact.rounded(.towardZero)
        carry = final ? 0 : exact - whole
        return Int32(clamping: Int64(whole))
    }
}
