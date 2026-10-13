import Combine
import CoreGraphics
import Foundation
import os

/// Applies `ScrollSettings` to mouse-wheel events through an active session event tap.
///
/// The tap exists only while it has something to do: a setting changes scrolling, Accessibility
/// is granted (active taps need it), and an MX Vertical is connected unless the user opted out of
/// that restriction. Trackpad and Magic Mouse (continuous) scrolling always passes through.
@MainActor
final class ScrollController: ObservableObject {
    /// True while the event tap is installed and rewriting wheel events.
    @Published private(set) var isActive = false

    private var tap: ScrollEventTap?
    private var loggedFailure = false
    private let logger = Logger(subsystem: "Upright", category: "Scrolling")

    func update(settings: ScrollSettings, accessibilityTrusted: Bool, mxVerticalConnected: Bool) {
        let wanted = settings.transformsEvents
            && accessibilityTrusted
            && (mxVerticalConnected || !settings.onlyWhileMXVerticalConnected)
        guard wanted else {
            stop()
            return
        }
        if let tap {
            tap.apply(settings)
            return
        }
        let tap = ScrollEventTap(settings: settings)
        guard tap.start() else {
            if !loggedFailure {
                logger.error("Could not create the scroll event tap")
                loggedFailure = true
            }
            return
        }
        loggedFailure = false
        self.tap = tap
        isActive = true
        logger.info("Scroll event tap installed")
    }

    func stop() {
        guard let tap else { return }
        tap.stop()
        self.tap = nil
        isActive = false
        logger.info("Scroll event tap removed")
    }
}

/// The tap itself. Runs on its own thread so a busy main thread never stalls scrolling
/// system-wide. Everything except `start`/`apply`/`stop` happens on that thread.
private final class ScrollEventTap: @unchecked Sendable {
    /// Marks events Upright posts (smooth scrolling) so the tap lets them through. "UPRT".
    static let syntheticMarker: Int64 = 0x5550_5254
    private static let frameInterval: CFTimeInterval = 1.0 / 120

    private var settings: ScrollSettings
    private var transform: ScrollTransform
    private var animator = SmoothScrollAnimator()
    private var lastFlags: CGEventFlags = []
    private var port: CFMachPort?
    private var runLoop: CFRunLoop?
    private var frameTimer: CFRunLoopTimer?

    init(settings: ScrollSettings) {
        self.settings = settings
        transform = ScrollTransform(settings: settings)
    }

    /// Creates the tap on a new thread and waits until it is listening. False when macOS refused.
    func start() -> Bool {
        let ready = DispatchSemaphore(value: 0)
        let thread = Thread { [self] in
            let mask = CGEventMask(1) << CGEventType.scrollWheel.rawValue
            guard let port = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: .defaultTap,
                eventsOfInterest: mask,
                callback: { _, type, event, userInfo in
                    guard let userInfo else { return Unmanaged.passUnretained(event) }
                    return Unmanaged<ScrollEventTap>.fromOpaque(userInfo).takeUnretainedValue().handle(type, event)
                },
                userInfo: Unmanaged.passUnretained(self).toOpaque()
            ) else {
                ready.signal()
                return
            }
            let runLoop = CFRunLoopGetCurrent()
            CFRunLoopAddSource(runLoop, CFMachPortCreateRunLoopSource(nil, port, 0), .commonModes)
            CGEvent.tapEnable(tap: port, enable: true)
            self.port = port
            self.runLoop = runLoop
            ready.signal()
            CFRunLoopRun()
        }
        thread.name = "Upright scroll tap"
        thread.qualityOfService = .userInteractive
        thread.start()
        ready.wait()
        return port != nil
    }

    func apply(_ settings: ScrollSettings) {
        perform { tap in
            if tap.settings.smoothScrolling, !settings.smoothScrolling { tap.finishAnimation() }
            tap.settings = settings
            tap.transform.settings = settings
        }
    }

    func stop() {
        perform { tap in
            tap.finishAnimation()
            if let port = tap.port {
                CGEvent.tapEnable(tap: port, enable: false)
                CFMachPortInvalidate(port)
            }
            tap.port = nil
            CFRunLoopStop(CFRunLoopGetCurrent())
        }
    }

    private func perform(_ body: @escaping (ScrollEventTap) -> Void) {
        guard let runLoop else { return }
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.commonModes.rawValue) { [self] in body(self) }
        CFRunLoopWakeUp(runLoop)
    }

    // MARK: Tap thread

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let port { CGEvent.tapEnable(tap: port, enable: true) }
            return Unmanaged.passUnretained(event)
        case .scrollWheel:
            break
        default:
            return Unmanaged.passUnretained(event)
        }
        guard event.getIntegerValueField(.eventSourceUserData) != Self.syntheticMarker,
              event.getIntegerValueField(.scrollWheelEventIsContinuous) == 0
        else { return Unmanaged.passUnretained(event) }

        let input = ScrollWheelDelta(
            lineAxis1: event.getIntegerValueField(.scrollWheelEventDeltaAxis1),
            lineAxis2: event.getIntegerValueField(.scrollWheelEventDeltaAxis2),
            pointAxis1: event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1),
            pointAxis2: event.getIntegerValueField(.scrollWheelEventPointDeltaAxis2),
            fixedPtAxis1: event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1),
            fixedPtAxis2: event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2)
        )
        let output = transform.apply(input, isContinuous: false)

        if settings.smoothScrolling {
            animate(output, flags: event.flags)
            return nil
        }
        if output != input {
            // Line deltas first: setting them makes CoreGraphics recompute the other fields.
            event.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: output.lineAxis1)
            event.setIntegerValueField(.scrollWheelEventDeltaAxis2, value: output.lineAxis2)
            event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: output.fixedPtAxis1)
            event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: output.fixedPtAxis2)
            event.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: output.pointAxis1)
            event.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: output.pointAxis2)
        }
        return Unmanaged.passUnretained(event)
    }

    // MARK: Smooth scrolling (experimental)

    private func animate(_ delta: ScrollWheelDelta, flags: CGEventFlags) {
        let vertical = SmoothScrollAnimator.distance(lines: delta.lineAxis1, fixedPtLines: delta.fixedPtAxis1)
        let horizontal = SmoothScrollAnimator.distance(lines: delta.lineAxis2, fixedPtLines: delta.fixedPtAxis2)
        lastFlags = flags
        animator.add(vertical: vertical, horizontal: horizontal, at: ProcessInfo.processInfo.systemUptime)
        guard animator.isActive, frameTimer == nil, let runLoop else { return }
        // The first frame goes out right away; the rest at roughly display rate.
        let timer = CFRunLoopTimerCreateWithHandler(nil, CFAbsoluteTimeGetCurrent(), Self.frameInterval, 0, 0) { [weak self] _ in
            self?.postNextFrame()
        }
        CFRunLoopAddTimer(runLoop, timer, .commonModes)
        frameTimer = timer
    }

    private func postNextFrame() {
        guard let frame = animator.step(at: ProcessInfo.processInfo.systemUptime) else {
            stopFrameTimer()
            return
        }
        post(frame)
        if !animator.isActive { stopFrameTimer() }
    }

    /// Ends a running animation right away so apps don't wait for a gesture end.
    private func finishAnimation() {
        if animator.isActive {
            post(SmoothScrollAnimator.Frame(vertical: 0, horizontal: 0, phase: .ended))
        }
        animator.cancel()
        stopFrameTimer()
    }

    private func stopFrameTimer() {
        if let frameTimer { CFRunLoopTimerInvalidate(frameTimer) }
        frameTimer = nil
    }

    private func post(_ frame: SmoothScrollAnimator.Frame) {
        guard let event = CGEvent(
            scrollWheelEvent2Source: nil,
            units: .pixel,
            wheelCount: 2,
            wheel1: frame.vertical,
            wheel2: frame.horizontal,
            wheel3: 0
        ) else { return }
        let phase: CGScrollPhase
        switch frame.phase {
        case .began: phase = .began
        case .changed: phase = .changed
        case .ended: phase = .ended
        }
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        event.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(phase.rawValue))
        event.setIntegerValueField(.eventSourceUserData, value: Self.syntheticMarker)
        // Keeps Shift-scroll and similar modifier behavior working.
        event.flags = lastFlags
        event.post(tap: .cgSessionEventTap)
    }
}
