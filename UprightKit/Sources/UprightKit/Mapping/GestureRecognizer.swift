import Foundation

/// Tells a hold-and-move gesture from a click, from the movement reported while the button is held.
///
/// Movement accumulates until it travels `threshold` units; the dominant axis then picks the
/// direction, which is reported once. Later movement is ignored until the next press. A release
/// before any direction fired is a tap. Deltas use screen orientation: positive dy is down.
public struct GestureRecognizer: Hashable, Sendable {
    /// For cursor movement (the fallback for buttons that can't report raw movement), in points.
    public static let cursorThreshold: Double = 40
    /// How far the hand must move, for raw sensor movement.
    public static let rawThresholdMillimeters: Double = 6
    /// Assumed when the mouse hasn't reported its pointer speed.
    public static let fallbackDPI = 1000

    /// `rawThresholdMillimeters` in sensor counts at `dpi`. Raw movement is reported in counts at
    /// the current resolution, so a fixed count would be under a millimeter at high DPI.
    public static func rawThreshold(dpi: Int?) -> Double {
        let dpi = dpi.flatMap { $0 > 0 ? $0 : nil } ?? fallbackDPI
        return rawThresholdMillimeters / 25.4 * Double(dpi)
    }

    public var threshold: Double
    public private(set) var dx: Double = 0
    public private(set) var dy: Double = 0
    /// The direction that fired during this hold, if any.
    public private(set) var firedDirection: GestureDirection?

    public init(threshold: Double = Self.cursorThreshold) {
        self.threshold = threshold
    }

    /// Adds movement and returns a direction the first time the threshold is crossed.
    public mutating func add(dx: Int, dy: Int) -> GestureDirection? {
        guard firedDirection == nil else { return nil }
        self.dx += Double(dx)
        self.dy += Double(dy)
        guard (self.dx * self.dx + self.dy * self.dy).squareRoot() >= threshold else { return nil }
        let direction: GestureDirection = abs(self.dx) >= abs(self.dy)
            ? (self.dx < 0 ? .left : .right)
            : (self.dy < 0 ? .up : .down)
        firedDirection = direction
        return direction
    }

    /// True when the hold ended without a direction firing, i.e. it was a tap.
    public var isTap: Bool { firedDirection == nil }
}
