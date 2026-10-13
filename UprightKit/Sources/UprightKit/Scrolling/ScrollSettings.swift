import Foundation

/// How Upright rewrites mouse-wheel scrolling. Trackpad and Magic Mouse scrolling is never touched.
public struct ScrollSettings: Codable, Hashable, Sendable {
    public static let speedRange: ClosedRange<Double> = 0.5...3.0
    public static let `default` = ScrollSettings()

    public var reverseVertical: Bool
    public var reverseHorizontal: Bool
    /// Multiplies wheel distance; clamped to `speedRange`.
    public var speed: Double {
        didSet { speed = Self.clampedSpeed(speed) }
    }
    /// Experimental: turns each wheel notch into a short eased run of pixel scrolls.
    public var smoothScrolling: Bool
    /// Only rewrite scrolling while a supported Logitech mouse is connected or asleep. Events
    /// don't say which mouse sent them, so either way every mouse wheel is affected; this only
    /// decides whether Upright steps aside when no supported mouse is around.
    ///
    /// Saved as `onlyWhileMXVerticalConnected` (see `CodingKeys`): the name predates support for
    /// other mice and must not change, or existing saves would lose the setting.
    public var onlyWhileMouseConnected: Bool

    /// The old Swift name of `onlyWhileMouseConnected`.
    @available(*, deprecated, renamed: "onlyWhileMouseConnected")
    public var onlyWhileMXVerticalConnected: Bool {
        get { onlyWhileMouseConnected }
        set { onlyWhileMouseConnected = newValue }
    }

    public init(
        reverseVertical: Bool = false,
        reverseHorizontal: Bool = false,
        speed: Double = 1,
        smoothScrolling: Bool = false,
        onlyWhileMouseConnected: Bool = true
    ) {
        self.reverseVertical = reverseVertical
        self.reverseHorizontal = reverseHorizontal
        self.speed = Self.clampedSpeed(speed)
        self.smoothScrolling = smoothScrolling
        self.onlyWhileMouseConnected = onlyWhileMouseConnected
    }

    /// True when any setting changes wheel events, i.e. when an event tap is worth installing.
    public var transformsEvents: Bool {
        reverseVertical || reverseHorizontal || !hasNeutralSpeed || smoothScrolling
    }

    var hasNeutralSpeed: Bool { abs(speed - 1) < 0.001 }

    private static func clampedSpeed(_ speed: Double) -> Double {
        guard speed.isFinite else { return 1 }
        return min(max(speed, speedRange.lowerBound), speedRange.upperBound)
    }

    private enum CodingKeys: String, CodingKey {
        case reverseVertical, reverseHorizontal, speed, smoothScrolling
        /// The stored key keeps its pre-multi-mouse name.
        case onlyWhileMouseConnected = "onlyWhileMXVerticalConnected"
    }

    /// Missing or unreadable keys fall back to their defaults, so older or newer saves still load.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            ((try? c.decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback
        }
        self.init(
            reverseVertical: value(.reverseVertical, false),
            reverseHorizontal: value(.reverseHorizontal, false),
            speed: value(.speed, 1.0),
            smoothScrolling: value(.smoothScrolling, false),
            onlyWhileMouseConnected: value(.onlyWhileMouseConnected, true)
        )
    }
}
