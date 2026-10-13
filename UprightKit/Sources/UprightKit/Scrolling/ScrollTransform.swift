import Foundation

/// The distance fields of one scroll-wheel event. Axis 1 is vertical, axis 2 horizontal,
/// matching the CGEvent fields of the same names.
public struct ScrollWheelDelta: Hashable, Sendable {
    /// Whole lines (`scrollWheelEventDeltaAxis1/2`).
    public var lineAxis1: Int64
    public var lineAxis2: Int64
    /// Pixels (`scrollWheelEventPointDeltaAxis1/2`).
    public var pointAxis1: Int64
    public var pointAxis2: Int64
    /// Fractional lines (`scrollWheelEventFixedPtDeltaAxis1/2`).
    public var fixedPtAxis1: Double
    public var fixedPtAxis2: Double

    public init(lineAxis1: Int64 = 0, lineAxis2: Int64 = 0, pointAxis1: Int64 = 0, pointAxis2: Int64 = 0, fixedPtAxis1: Double = 0, fixedPtAxis2: Double = 0) {
        self.lineAxis1 = lineAxis1
        self.lineAxis2 = lineAxis2
        self.pointAxis1 = pointAxis1
        self.pointAxis2 = pointAxis2
        self.fixedPtAxis1 = fixedPtAxis1
        self.fixedPtAxis2 = fixedPtAxis2
    }
}

/// Applies `ScrollSettings` to wheel events. Stateful: integer deltas scaled by a slow speed
/// carry their fractional part to the next event, so 0.5× moves one line every second notch
/// instead of never.
public struct ScrollTransform: Sendable {
    public var settings: ScrollSettings {
        didSet {
            if settings.speed != oldValue.speed { resetRemainders() }
        }
    }

    private var lineRemainder1 = 0.0
    private var lineRemainder2 = 0.0
    private var pointRemainder1 = 0.0
    private var pointRemainder2 = 0.0

    public init(settings: ScrollSettings = .default) {
        self.settings = settings
    }

    /// Continuous events (trackpads, Magic Mouse) pass through untouched.
    public mutating func apply(_ delta: ScrollWheelDelta, isContinuous: Bool) -> ScrollWheelDelta {
        guard !isContinuous else { return delta }
        let speed = settings.hasNeutralSpeed ? 1 : settings.speed
        let sign1: Int64 = settings.reverseVertical ? -1 : 1
        let sign2: Int64 = settings.reverseHorizontal ? -1 : 1

        var out = delta
        if speed != 1 {
            out.lineAxis1 = Self.scale(delta.lineAxis1, by: speed, remainder: &lineRemainder1)
            out.lineAxis2 = Self.scale(delta.lineAxis2, by: speed, remainder: &lineRemainder2)
            out.pointAxis1 = Self.scale(delta.pointAxis1, by: speed, remainder: &pointRemainder1)
            out.pointAxis2 = Self.scale(delta.pointAxis2, by: speed, remainder: &pointRemainder2)
            out.fixedPtAxis1 = delta.fixedPtAxis1 * speed
            out.fixedPtAxis2 = delta.fixedPtAxis2 * speed
        }
        out.lineAxis1 *= sign1
        out.pointAxis1 *= sign1
        out.fixedPtAxis1 *= Double(sign1)
        out.lineAxis2 *= sign2
        out.pointAxis2 *= sign2
        out.fixedPtAxis2 *= Double(sign2)
        return out
    }

    public mutating func resetRemainders() {
        lineRemainder1 = 0
        lineRemainder2 = 0
        pointRemainder1 = 0
        pointRemainder2 = 0
    }

    /// Scales an integer delta, keeping the fractional part for the next call. A change of
    /// direction drops the carried part so reversing responds immediately.
    static func scale(_ value: Int64, by factor: Double, remainder: inout Double) -> Int64 {
        guard value != 0 else { return 0 }
        if remainder != 0, (remainder > 0) != (value > 0) { remainder = 0 }
        let exact = Double(value) * factor + remainder
        let whole = exact.rounded(.towardZero)
        remainder = exact - whole
        return Int64(whole)
    }
}
