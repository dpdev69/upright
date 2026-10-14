import XCTest
@testable import UprightKit

final class ScrollTransformTests: XCTestCase {
    private let notchDown = ScrollWheelDelta(lineAxis1: -1, pointAxis1: -10, fixedPtAxis1: -1)
    private let notchRight = ScrollWheelDelta(lineAxis2: 1, pointAxis2: 10, fixedPtAxis2: 1)

    func testDefaultsLeaveEventsAlone() {
        XCTAssertFalse(ScrollSettings.default.transformsEvents)
        var transform = ScrollTransform()
        XCTAssertEqual(transform.apply(notchDown, isContinuous: false), notchDown)
        XCTAssertEqual(transform.apply(notchRight, isContinuous: false), notchRight)
    }

    func testReverseVerticalOnly() {
        var transform = ScrollTransform(settings: ScrollSettings(reverseVertical: true))
        XCTAssertEqual(
            transform.apply(notchDown, isContinuous: false),
            ScrollWheelDelta(lineAxis1: 1, pointAxis1: 10, fixedPtAxis1: 1)
        )
        XCTAssertEqual(transform.apply(notchRight, isContinuous: false), notchRight)
    }

    func testReverseHorizontalOnly() {
        var transform = ScrollTransform(settings: ScrollSettings(reverseHorizontal: true))
        XCTAssertEqual(transform.apply(notchDown, isContinuous: false), notchDown)
        XCTAssertEqual(
            transform.apply(notchRight, isContinuous: false),
            ScrollWheelDelta(lineAxis2: -1, pointAxis2: -10, fixedPtAxis2: -1)
        )
    }

    func testContinuousEventsPassThrough() {
        let trackpad = ScrollWheelDelta(lineAxis1: 3, lineAxis2: -1, pointAxis1: 27, pointAxis2: -4, fixedPtAxis1: 2.7, fixedPtAxis2: -0.4)
        var transform = ScrollTransform(settings: ScrollSettings(reverseVertical: true, reverseHorizontal: true, speed: 2.5))
        XCTAssertEqual(transform.apply(trackpad, isContinuous: true), trackpad)
    }

    func testFastSpeedScalesEveryField() {
        var transform = ScrollTransform(settings: ScrollSettings(speed: 3))
        XCTAssertEqual(
            transform.apply(notchDown, isContinuous: false),
            ScrollWheelDelta(lineAxis1: -3, pointAxis1: -30, fixedPtAxis1: -3)
        )
    }

    func testSlowSpeedCarriesFractionsSoNotchesStillScroll() {
        var transform = ScrollTransform(settings: ScrollSettings(speed: 0.5))
        let first = transform.apply(notchDown, isContinuous: false)
        XCTAssertEqual(first.lineAxis1, 0)
        XCTAssertEqual(first.pointAxis1, -5)
        XCTAssertEqual(first.fixedPtAxis1, -0.5)
        let second = transform.apply(notchDown, isContinuous: false)
        XCTAssertEqual(second.lineAxis1, -1)

        let lines = (0..<10).map { _ in transform.apply(notchDown, isContinuous: false).lineAxis1 }
        XCTAssertEqual(lines.reduce(0, +), -5)
    }

    func testDirectionChangeDropsCarriedFraction() {
        var transform = ScrollTransform(settings: ScrollSettings(speed: 0.5))
        _ = transform.apply(notchDown, isContinuous: false)
        // Without the reset, the -0.5 carried from scrolling down would cost the next notch up a line.
        let up = transform.apply(ScrollWheelDelta(lineAxis1: 1, pointAxis1: 10, fixedPtAxis1: 1), isContinuous: false)
        XCTAssertEqual(up.lineAxis1, 0)
        XCTAssertEqual(transform.apply(ScrollWheelDelta(lineAxis1: 1), isContinuous: false).lineAxis1, 1)
    }

    func testOddSpeedRoundsWithoutDrift() {
        var transform = ScrollTransform(settings: ScrollSettings(speed: 1.5))
        let lines = (0..<4).map { _ in transform.apply(ScrollWheelDelta(lineAxis1: 1), isContinuous: false).lineAxis1 }
        XCTAssertEqual(lines, [1, 2, 1, 2])
    }

    func testSpeedAndReverseCombine() {
        var transform = ScrollTransform(settings: ScrollSettings(reverseHorizontal: true, speed: 2))
        XCTAssertEqual(
            transform.apply(notchRight, isContinuous: false),
            ScrollWheelDelta(lineAxis2: -2, pointAxis2: -20, fixedPtAxis2: -2)
        )
    }

    func testAxesKeepSeparateRemainders() {
        var transform = ScrollTransform(settings: ScrollSettings(speed: 0.5))
        _ = transform.apply(ScrollWheelDelta(lineAxis1: 1), isContinuous: false)
        _ = transform.apply(ScrollWheelDelta(lineAxis2: 1), isContinuous: false)
        XCTAssertEqual(transform.apply(ScrollWheelDelta(lineAxis1: 1), isContinuous: false).lineAxis1, 1)
        XCTAssertEqual(transform.apply(ScrollWheelDelta(lineAxis2: 1), isContinuous: false).lineAxis2, 1)
    }

    // MARK: Settings

    func testSpeedIsClamped() {
        XCTAssertEqual(ScrollSettings(speed: 10).speed, 3)
        XCTAssertEqual(ScrollSettings(speed: 0).speed, 0.5)
        var settings = ScrollSettings()
        settings.speed = .nan
        XCTAssertEqual(settings.speed, 1)
    }

    func testTransformsEvents() {
        XCTAssertTrue(ScrollSettings(reverseVertical: true).transformsEvents)
        XCTAssertTrue(ScrollSettings(speed: 1.25).transformsEvents)
        XCTAssertTrue(ScrollSettings(smoothScrolling: true).transformsEvents)
        XCTAssertFalse(ScrollSettings(onlyWhileMouseConnected: false).transformsEvents)
    }

    func testSettingsRoundTripAndTolerantDecoding() throws {
        let settings = ScrollSettings(reverseVertical: true, speed: 1.5, smoothScrolling: true, onlyWhileMouseConnected: false)
        let data = try JSONEncoder().encode(settings)
        XCTAssertEqual(try JSONDecoder().decode(ScrollSettings.self, from: data), settings)

        let partial = #"{"reverseHorizontal":true,"speed":"fast","futureKey":1}"#
        XCTAssertEqual(
            try JSONDecoder().decode(ScrollSettings.self, from: Data(partial.utf8)),
            ScrollSettings(reverseHorizontal: true)
        )
        XCTAssertEqual(try JSONDecoder().decode(ScrollSettings.self, from: Data("{}".utf8)), .default)
        XCTAssertEqual(try JSONDecoder().decode(ScrollSettings.self, from: Data(#"{"speed":99}"#.utf8)).speed, 3)
    }

    /// The Swift property was renamed for multi-mouse support, but saves keep the old key.
    func testOnlyWhileMouseConnectedKeepsItsStoredKey() throws {
        XCTAssertTrue(ScrollSettings.default.onlyWhileMouseConnected)

        let old = try JSONDecoder().decode(ScrollSettings.self, from: Data(#"{"onlyWhileMXVerticalConnected":false}"#.utf8))
        XCTAssertFalse(old.onlyWhileMouseConnected)
        let oldTrue = try JSONDecoder().decode(ScrollSettings.self, from: Data(#"{"onlyWhileMXVerticalConnected":true}"#.utf8))
        XCTAssertTrue(oldTrue.onlyWhileMouseConnected)

        let encoded = try JSONEncoder().encode(ScrollSettings(onlyWhileMouseConnected: false))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual(object["onlyWhileMXVerticalConnected"] as? Bool, false)
        XCTAssertNil(object["onlyWhileMouseConnected"])
        XCTAssertEqual(
            Set(object.keys),
            ["reverseVertical", "reverseHorizontal", "speed", "smoothScrolling", "onlyWhileMXVerticalConnected"]
        )

        // A save under the new Swift name is not a thing: it is ignored and the default applies.
        let wrongKey = try JSONDecoder().decode(ScrollSettings.self, from: Data(#"{"onlyWhileMouseConnected":false}"#.utf8))
        XCTAssertTrue(wrongKey.onlyWhileMouseConnected)
    }

    func testDeprecatedAliasStillReadsAndWritesTheRenamedProperty() {
        var settings = ScrollSettings(onlyWhileMouseConnected: false)
        XCTAssertFalse(settings.onlyWhileMXVerticalConnected)
        settings.onlyWhileMXVerticalConnected = true
        XCTAssertTrue(settings.onlyWhileMouseConnected)
        settings.onlyWhileMouseConnected = false
        XCTAssertFalse(settings.onlyWhileMXVerticalConnected)
    }
}

final class SmoothScrollAnimatorTests: XCTestCase {
    private func run(_ animator: inout SmoothScrollAnimator, from start: Double, until end: Double, step: Double = 1.0 / 120) -> [SmoothScrollAnimator.Frame] {
        var frames: [SmoothScrollAnimator.Frame] = []
        var t = start
        while t <= end, let frame = animator.step(at: t) {
            frames.append(frame)
            t += step
        }
        return frames
    }

    func testEmitsExactDistanceWithPhases() throws {
        var animator = SmoothScrollAnimator(duration: 0.18)
        XCTAssertNil(animator.step(at: 0))
        animator.add(vertical: -37, horizontal: 0, at: 0)
        let frames = run(&animator, from: 0.008, until: 1)
        XCTAssertEqual(frames.map(\.vertical).reduce(0, +), -37)
        XCTAssertEqual(frames.first?.phase, .began)
        XCTAssertEqual(frames.last, .init(vertical: 0, horizontal: 0, phase: .ended))
        XCTAssertTrue(frames.dropFirst().dropLast().allSatisfy { $0.phase == .changed })
        XCTAssertFalse(animator.isActive)
        // Ease-out: the first frames move more than the last ones.
        let moving = frames.dropLast().map { abs($0.vertical) }
        XCTAssertGreaterThan(try XCTUnwrap(moving.first), try XCTUnwrap(moving.last))
    }

    func testNotchesMidAnimationAccumulate() {
        var animator = SmoothScrollAnimator(duration: 0.18)
        animator.add(vertical: 40, horizontal: 0, at: 0)
        var frames = run(&animator, from: 0.01, until: 0.05)
        animator.add(vertical: 40, horizontal: 0, at: 0.06)
        frames += run(&animator, from: 0.07, until: 2)
        XCTAssertEqual(frames.map(\.vertical).reduce(0, +), 80)
        XCTAssertEqual(frames.filter { $0.phase == .began }.count, 1)
        XCTAssertEqual(frames.filter { $0.phase == .ended }.count, 1)
    }

    func testReversingDropsWhatIsLeft() {
        var animator = SmoothScrollAnimator(duration: 0.2)
        animator.add(vertical: 100, horizontal: 0, at: 0)
        let before = run(&animator, from: 0.01, until: 0.05).map(\.vertical).reduce(0, +)
        animator.add(vertical: -30, horizontal: 0, at: 0.06)
        let after = run(&animator, from: 0.07, until: 2).map(\.vertical).reduce(0, +)
        XCTAssertGreaterThan(before, 0)
        XCTAssertEqual(after, -30)
    }

    func testHorizontalAndCancel() {
        var animator = SmoothScrollAnimator()
        animator.add(vertical: 0, horizontal: 25, at: 0)
        XCTAssertTrue(animator.isActive)
        let frames = run(&animator, from: 0.01, until: 1)
        XCTAssertEqual(frames.map(\.horizontal).reduce(0, +), 25)
        XCTAssertEqual(frames.map(\.vertical).reduce(0, +), 0)

        animator.add(vertical: 10, horizontal: 0, at: 2)
        animator.cancel()
        XCTAssertNil(animator.step(at: 2.01))
    }
}
