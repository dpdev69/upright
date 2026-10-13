import AppKit
import SwiftUI

/// `Upright --demo --export-snapshots <dir>`: renders the real UI offscreen, driven by the
/// simulated fleet (`DemoMode.Fleet`) with the demo setup (`DemoMode.Scenario`), and writes
/// `<id>.<light|dark>.png` plus `manifest.json` (sizes and `snapshotAnchor` rects, in points with
/// a top-left origin) to a directory. See docs/dev/DEMO-MODE-SPEC.md.
///
/// - Settings states use the settings window's own view tree in a window of its default size
///   (780 × 560 points) that is never shown; the Mice pane's states are taller so the mouse list,
///   pointer speed and presets fit in one image.
/// - The menu bar panel is rendered at its natural size; the menu bar label with ImageRenderer at 6x.
/// - Nothing is put on screen, no input event is posted, IOKit is never used and the user's
///   defaults domain is never read or written (Demo Mode's own suite holds the demo setup).
/// - Offscreen, AppKit draws an inactive app's windows and can't render materials that blend
///   with the desktop (Liquid Glass, vibrancy). This process therefore reports itself active
///   (`ActiveAppearance`), and `capture` stands in for the glass sidebar. The frontmost app the
///   profile UI mentions is a standard Apple app announced in-process (`DemoMode.pretendFrontmost`).
///
/// Development: `UPRIGHT_SNAPSHOT_ONLY=<id prefix>` renders only matching states;
/// `UPRIGHT_SNAPSHOT_DEBUG=1` logs each settings window's view hierarchy.
@MainActor
enum SnapshotExporter {
    enum ExportError: Error, CustomStringConvertible {
        case miceDidNotConnect(String)
        case missingStates([String])
        case writeFailed(String)

        var description: String {
            switch self {
            case .miceDidNotConnect(let detail): return "The simulated mice did not connect: \(detail)"
            case .missingStates(let ids): return "These essential states could not be rendered: \(ids.joined(separator: ", "))"
            case .writeFailed(let detail): return "Could not write the snapshots: \(detail)"
            }
        }
    }

    /// The settings window's default content size (`SettingsWindowController`).
    static let settingsSize = CGSize(width: 780, height: 560)
    static let defaultScale: CGFloat = 2
    static let labelScale: CGFloat = 6

    /// `model` is the app's own Demo Mode model; the export builds a second one around its own
    /// simulated fleet so it can set battery levels and other device state, and leaves `model`
    /// alone.
    static func run(model: AppModel, to directory: URL) async throws {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw ExportError.writeFailed("\(directory.path): \(error.localizedDescription)")
        }
        let session = try await Session.start()
        defer { session.stop() }

        var entries: [ManifestEntry] = []
        var failures: [String] = []
        // UPRIGHT_SNAPSHOT_ONLY=<prefix>: only the states whose id starts with it (for development).
        let only = ProcessInfo.processInfo.environment["UPRIGHT_SNAPSHOT_ONLY"]
        for state in States.all where only.map(state.id.hasPrefix) ?? true {
            for appearance in Appearance.allCases {
                do {
                    let image = try await session.render(state, appearance: appearance)
                    let file = "\(state.id).\(appearance.rawValue).png"
                    try write(image.png, to: directory.appendingPathComponent(file))
                    entries.append(ManifestEntry(
                        id: state.id,
                        appearance: appearance.rawValue,
                        file: file,
                        scale: image.scale,
                        size: .init(w: image.size.width, h: image.size.height),
                        rects: image.rects.mapValues(ManifestEntry.Rect.init)
                    ))
                    log("\(file)  \(Int(image.size.width))×\(Int(image.size.height)) pt  \(image.rects.count) rects")
                } catch {
                    log("\(state.id).\(appearance.rawValue): \(error)")
                    failures.append(state.id)
                }
            }
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        do {
            try write(try encoder.encode(entries), to: directory.appendingPathComponent("manifest.json"))
        } catch let error as ExportError {
            throw error
        } catch {
            throw ExportError.writeFailed("manifest.json: \(error.localizedDescription)")
        }
        log("Wrote \(entries.count) images and manifest.json to \(directory.path)")

        let missing = Set(failures).intersection(States.all.filter(\.isEssential).map(\.id))
        if !missing.isEmpty { throw ExportError.missingStates(missing.sorted()) }
    }

    private static func write(_ data: Data, to url: URL) throws {
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            throw ExportError.writeFailed("\(url.lastPathComponent): \(error.localizedDescription)")
        }
    }

    fileprivate static func log(_ text: String) {
        FileHandle.standardError.write(Data("[snapshots] \(text)\n".utf8))
    }
}

// MARK: - Manifest

extension SnapshotExporter {
    struct ManifestEntry: Encodable {
        struct Size: Encodable {
            let w: Double
            let h: Double
        }

        struct Rect: Encodable {
            let x: Double
            let y: Double
            let w: Double
            let h: Double

            init(_ rect: CGRect) {
                func rounded(_ value: CGFloat) -> Double { (Double(value) * 100).rounded() / 100 }
                x = rounded(rect.minX)
                y = rounded(rect.minY)
                w = rounded(rect.width)
                h = rounded(rect.height)
            }
        }

        let id: String
        let appearance: String
        let file: String
        let scale: Double
        let size: Size
        let rects: [String: Rect]
    }

    enum Appearance: String, CaseIterable {
        case light
        case dark

        var nsAppearance: NSAppearance {
            NSAppearance(named: self == .light ? .aqua : .darkAqua)!
        }

        var colorScheme: ColorScheme { self == .light ? .light : .dark }
    }

    /// One rendered image: PNG data, its size in points, and the named rects in it.
    struct RenderedImage {
        let png: Data
        let size: CGSize
        let scale: Double
        let rects: [String: CGRect]
    }
}

// MARK: - States

extension SnapshotExporter {
    /// One UI state to capture.
    struct State {
        enum Surface {
            /// The settings window on a pane.
            case settings(SettingsPane)
            /// The menu bar panel.
            case menuPanel
            /// The status item's label.
            case menuLabel
        }

        /// Where the settings pane's form scrolls to before the capture.
        enum Scroll {
            case top
            /// The anchor with this name, near the top of the pane.
            case anchor(String)
            case bottom
        }

        let id: String
        let isEssential: Bool
        let surface: Surface
        var scroll: Scroll = .top
        /// The settings window's content size; nil for the default.
        var size: CGSize?
        /// Ends the window this far below the named anchor (the window is resized after the
        /// first layout).
        var fitBelow: (anchor: String, padding: CGFloat)?
        /// Puts the model and the mice into the state (runs before the view is built).
        var prepare: @MainActor (Session) async -> Void
        /// Runs once the view is laid out (e.g. picks a profile in the Buttons pane). Returns
        /// false when the state couldn't be reached.
        var interact: (@MainActor (Session, NSView) async -> Bool)?
        /// Puts back what `prepare` changed that later states don't set themselves.
        var cleanUp: @MainActor (Session) async -> Void = { _ in }

        /// `prepare` has no default, so a single trailing closure is always `prepare` (with
        /// defaults on every closure, Swift 5 mode matches it backwards, to `cleanUp`, which then
        /// ran after the capture).
        init(
            id: String,
            isEssential: Bool,
            surface: Surface,
            scroll: Scroll = .top,
            size: CGSize? = nil,
            fitBelow: (anchor: String, padding: CGFloat)? = nil,
            prepare: @escaping @MainActor (Session) async -> Void,
            interact: (@MainActor (Session, NSView) async -> Bool)? = nil,
            cleanUp: @escaping @MainActor (Session) async -> Void = { _ in }
        ) {
            self.id = id
            self.isEssential = isEssential
            self.surface = surface
            self.scroll = scroll
            self.size = size
            self.fitBelow = fitBelow
            self.prepare = prepare
            self.interact = interact
            self.cleanUp = cleanUp
        }
    }

    enum States {
        typealias Mouse = DemoMode.Fleet.Mouse
        typealias Scenario = DemoMode.Scenario

        /// The Mice pane is taller than the window's default so the list of mice, the pointer
        /// speed and the presets fit in one image (the window is resizable): laid out tall, then
        /// cut to end below the presets.
        static let micePaneSize = CGSize(width: 780, height: 1700)
        static let micePaneFit: (anchor: String, padding: CGFloat) = ("dpiPresets", 150)

        static var all: [State] {
            var states: [State] = []

            // Buttons
            states.append(State(id: "buttons.global", isEssential: true, surface: .settings(.buttons)) { session in
                session.showButtons(of: .vertical, frontmost: Scenario.finder)
            })
            for (index, action) in Scenario.topButtonVariants.enumerated() {
                states.append(State(id: "buttons.global.\(index + 1)", isEssential: false, surface: .settings(.buttons)) { session in
                    session.showButtons(of: .vertical, frontmost: Scenario.finder)
                    session.model.library[Mouse.vertical.modelKey].global[KnownControl.dpiSwitch] = action
                } cleanUp: { session in
                    session.model.library = Scenario.library
                })
            }
            states.append(State(id: "buttons.profile", isEssential: true, surface: .settings(.buttons)) { session in
                session.showButtons(of: .vertical, frontmost: Scenario.safari)
                session.openProfile(Scenario.safari)
            } interact: { session, _ in
                await session.showsProfile(Scenario.safari)
            } cleanUp: { session in
                session.openProfile(nil)
            })
            states.append(State(id: "buttons.profile.2", isEssential: false, surface: .settings(.buttons)) { session in
                session.showButtons(of: .vertical, frontmost: Scenario.music)
                session.openProfile(Scenario.music)
            } interact: { session, _ in
                await session.showsProfile(Scenario.music)
            } cleanUp: { session in
                session.openProfile(nil)
            })
            states.append(State(id: "gesture.editor", isEssential: true, surface: .settings(.buttons), scroll: .anchor("row.00FD")) { session in
                session.showButtons(of: .vertical, frontmost: Scenario.finder)
            })

            // Mice
            states.append(State(id: "device.pointer", isEssential: true, surface: .settings(.device), size: micePaneSize, fitBelow: micePaneFit) { session in
                await session.showMouse(.vertical, dpi: Scenario.pointerSpeeds[.vertical]!)
            })
            for dpi in [800, 1600, 3200] {
                states.append(State(id: "device.pointer.\(dpi)", isEssential: false, surface: .settings(.device), size: micePaneSize, fitBelow: micePaneFit) { session in
                    await session.showMouse(.vertical, dpi: dpi)
                } cleanUp: { session in
                    await session.setDPI(Scenario.pointerSpeeds[.vertical]!, of: .vertical)
                })
            }
            states.append(State(id: "device.activity", isEssential: false, surface: .settings(.device), scroll: .bottom) { session in
                await session.showActivityAfterWake()
            })

            // Scrolling, General
            states.append(State(id: "scrolling", isEssential: true, surface: .settings(.scrolling)) { session in
                session.pretendFrontmost(Scenario.finder)
            })
            states.append(State(id: "general.behavior", isEssential: true, surface: .settings(.general), scroll: .anchor("behavior.sleep")) { session in
                session.pretendFrontmost(Scenario.finder)
            })

            // Menu bar
            states.append(State(id: "menubar.panel", isEssential: true, surface: .menuPanel) { session in
                session.showMenu(frontmost: Scenario.finder)
            })
            states.append(State(id: "menubar.panel.lowbattery", isEssential: false, surface: .menuPanel) { session in
                session.showMenu(frontmost: Scenario.finder)
                await session.setBattery(Scenario.lowBatteryLevel, of: .lift)
            } cleanUp: { session in
                await session.setBattery(Scenario.batteryLevels[.lift]!, of: .lift)
            })
            states.append(State(id: "menubar.label", isEssential: false, surface: .menuLabel) { session in
                session.pretendFrontmost(Scenario.finder)
            })
            return states
        }
    }
}

// MARK: - Session

extension SnapshotExporter {
    /// The demo model, its fleet, and the offscreen rendering.
    @MainActor
    final class Session {
        let fleet: DemoMode.Fleet
        let model: AppModel
        /// Live addresses of the three mice.
        private(set) var addresses: [DemoMode.Fleet.Mouse: DeviceAddress] = [:]
        /// The login item as an installed copy of Upright sees it (no "move to Applications" warning).
        private let loginItem = LoginItemController(bundleURL: URL(fileURLWithPath: "/Applications/Upright.app", isDirectory: true))

        private init(fleet: DemoMode.Fleet, model: AppModel) {
            self.fleet = fleet
            self.model = model
        }

        static func start() async throws -> Session {
            ActiveAppearance.enable()
            let fleet = DemoMode.Fleet()
            let model = AppModel(environment: .demo, devices: DeviceManager(source: fleet.source))
            let session = Session(fleet: fleet, model: model)
            DemoMode.Scenario.apply(to: model)
            model.start()
            session.pretendFrontmost(DemoMode.Scenario.finder)
            try await session.waitForMice()
            fleet.settle()
            for mouse in DemoMode.Fleet.Mouse.allCases {
                await session.setBattery(DemoMode.Scenario.batteryLevels[mouse]!, of: mouse)
                await session.setDPI(DemoMode.Scenario.pointerSpeeds[mouse]!, of: mouse)
            }
            // The app's own wake message, as after a night's sleep.
            model.devices.systemDidWake()
            await session.settle(0.5)
            model.selectedDevice = session.addresses[.vertical]
            return session
        }

        func stop() {
            model.devices.shutdown()
        }

        // MARK: Device state

        private func waitForMice() async throws {
            let deadline = Date().addingTimeInterval(20)
            while Date() < deadline {
                var found: [DemoMode.Fleet.Mouse: DeviceAddress] = [:]
                for mouse in DemoMode.Fleet.Mouse.allCases {
                    let record = model.devices.records.first {
                        $0.model == mouse.modelKey && $0.role == .active && $0.isConnected
                            && $0.snapshot?.dpi != nil && $0.snapshot?.battery != nil
                    }
                    if let record { found[mouse] = record.address }
                }
                if found.count == DemoMode.Fleet.Mouse.allCases.count {
                    addresses = found
                    return
                }
                await settle(0.1)
            }
            let seen = model.devices.records.map { "\($0.displayName) (\($0.connection.title), \($0.stateText))" }
            throw ExportError.miceDidNotConnect(seen.isEmpty ? "no device appeared" : seen.joined(separator: "; "))
        }

        func setBattery(_ percentage: Int, of mouse: DemoMode.Fleet.Mouse) async {
            fleet.setBattery(percentage, of: mouse)
            await waitUntil { [self] in
                guard let address = addresses[mouse], let battery = model.devices.snapshot(address)?.battery else { return false }
                return abs(battery.percentage - percentage) <= 10
            }
        }

        func setDPI(_ dpi: Int, of mouse: DemoMode.Fleet.Mouse) async {
            guard let address = addresses[mouse] else { return }
            model.setPreferredDPI(dpi, for: address)
            await waitUntil { [self] in model.devices.snapshot(address)?.dpi?.current == dpi }
        }

        // MARK: UI state

        func pretendFrontmost(_ app: AppReference) {
            DemoMode.pretendFrontmost(app)
        }

        func showButtons(of mouse: DemoMode.Fleet.Mouse, frontmost: AppReference) {
            pretendFrontmost(frontmost)
            model.selectedPane = .buttons
            model.selectedDevice = addresses[mouse]
            model.selectedModel = mouse.modelKey
        }

        func showMouse(_ mouse: DemoMode.Fleet.Mouse, dpi: Int) async {
            pretendFrontmost(DemoMode.Scenario.finder)
            model.selectedPane = .device
            model.selectedDevice = addresses[mouse]
            await setDPI(dpi, of: mouse)
        }

        /// The activity log of a typical morning: the mice connect, then the Mac wakes and
        /// Upright reapplies every mouse's configuration (the app's own messages).
        func showActivityAfterWake() async {
            pretendFrontmost(DemoMode.Scenario.finder)
            model.selectedPane = .device
            model.devices.clearLog()
            model.devices.reconnect(nil)
            do {
                try await waitForMice()
            } catch {
                SnapshotExporter.log("\(error)")
            }
            model.selectedDevice = addresses[.vertical]
            await settle(0.5)
            model.devices.systemDidWake()
            await settle(1)
        }

        func showMenu(frontmost: AppReference) {
            pretendFrontmost(frontmost)
            model.selectedDevice = addresses[.vertical]
        }

        /// Opens the Buttons pane on an app's profile (`DemoMode.snapshotProfileBundleID`).
        func openProfile(_ app: AppReference?) {
            DemoMode.snapshotProfileBundleID = app?.bundleID
        }

        /// Whether the Buttons pane shows an app profile: its overridden rows are marked.
        func showsProfile(_ app: AppReference) async -> Bool {
            for _ in 0..<10 {
                if SnapshotAnchorCollector.shared.frames.keys.contains(where: { $0.hasPrefix("override.") }) { return true }
                await settle(0.1)
            }
            SnapshotExporter.log("The Buttons pane didn't open on the \(app.displayName) profile: ButtonsPane must seed its profile selection from DemoMode.snapshotProfileBundleID")
            return false
        }

        // MARK: Rendering

        func render(_ state: State, appearance: Appearance) async throws -> RenderedImage {
            SnapshotAnchorCollector.shared.reset()
            await state.prepare(self)
            await settle(0.3)
            do {
                let image: RenderedImage
                switch state.surface {
                case .settings:
                    image = try await renderSettings(state, appearance: appearance)
                case .menuPanel:
                    image = try await renderMenuPanel(appearance: appearance)
                case .menuLabel:
                    image = try renderMenuLabel(appearance: appearance)
                }
                await state.cleanUp(self)
                return image
            } catch {
                await state.cleanUp(self)
                throw error
            }
        }

        private func renderSettings(_ state: State, appearance: Appearance) async throws -> RenderedImage {
            let size = state.size ?? SnapshotExporter.settingsSize
            let window = Self.makeWindow(size: size, appearance: appearance, titled: true)
            let rects = RectStore()
            let controller = NSHostingController(rootView: AnyView(
                settingsContent().modifier(AnchorResolver(store: rects))
            ))
            window.contentViewController = controller
            window.setContentSize(size)
            ActiveAppearance.announce(window)
            defer { Self.dismantle(window) }

            if case .settings(let pane) = state.surface { model.selectedPane = pane }
            await layOut(window)
            // The sidebar's list can pick its first row while it is set up; choose the pane again.
            if case .settings(let pane) = state.surface, model.selectedPane != pane {
                model.selectedPane = pane
                await layOut(window)
            }
            if let fit = state.fitBelow {
                // Content above the anchor can still grow as the mouse's details arrive: repeat
                // until the window ends where it should.
                for _ in 0..<4 {
                    guard let anchor = SnapshotAnchorCollector.shared.frames[fit.anchor] else {
                        throw RenderError.stateNotReached("\(state.id): no \(fit.anchor) on screen")
                    }
                    let height = min(size.height, (anchor.maxY + fit.padding).rounded())
                    if ProcessInfo.processInfo.environment["UPRIGHT_SNAPSHOT_DEBUG"] != nil {
                        SnapshotExporter.log("fit: \(fit.anchor) at \(anchor), slider \(String(describing: SnapshotAnchorCollector.shared.frames["dpiSlider"])), window \(window.contentView?.bounds.height ?? 0) -> \(height)")
                    }
                    guard abs(height - (window.contentView?.bounds.height ?? 0)) >= 2 else { break }
                    window.setContentSize(CGSize(width: size.width, height: height))
                    await layOut(window)
                }
            }
            if ProcessInfo.processInfo.environment["UPRIGHT_SNAPSHOT_DEBUG"] != nil, let frame = window.contentView?.superview {
                Self.dump(frame, depth: 0)
            }
            if let interact = state.interact {
                guard await interact(self, window.contentView!) else {
                    throw RenderError.stateNotReached(state.id)
                }
                await layOut(window)
            }
            if case .top = state.scroll {} else {
                await scroll(window, to: state.scroll)
            }
            return try capture(window: window, appearance: appearance, preferenceRects: rects.rects)
        }

        private func renderMenuPanel(appearance: Appearance) async throws -> RenderedImage {
            let rects = RectStore()
            let content = MenuBarView()
                .environmentObject(model)
                .environmentObject(model.devices)
                .environmentObject(model.permissions)
                .environmentObject(model.settings)
                .modifier(AnchorResolver(store: rects))
            let hosting = NSHostingView(rootView: AnyView(content))
            let fitting = hosting.fittingSize
            let size = CGSize(width: max(320, min(fitting.width, 440)).rounded(), height: fitting.height.rounded())
            let window = Self.makeWindow(size: size, appearance: appearance, titled: false)
            window.contentView = hosting
            ActiveAppearance.announce(window)
            defer { Self.dismantle(window) }
            await layOut(window)
            // The height can change once the mice's rows have their final content.
            let settled = hosting.fittingSize
            if abs(settled.height - size.height) >= 1 {
                window.setContentSize(CGSize(width: size.width, height: settled.height.rounded()))
                await layOut(window)
            }
            return try capture(window: window, appearance: appearance, preferenceRects: rects.rects, panelCornerRadius: 10)
        }

        private func renderMenuLabel(appearance: Appearance) throws -> RenderedImage {
            let label = MenuBarLabel(devices: model.devices, settings: model.settings)
                .font(.system(size: 13))
                .foregroundStyle(.primary)
                .padding(.horizontal, 6)
                .frame(height: 22)
                .environment(\.colorScheme, appearance.colorScheme)
            let renderer = ImageRenderer(content: label)
            renderer.scale = SnapshotExporter.labelScale
            renderer.isOpaque = false
            guard let cgImage = renderer.cgImage else { throw RenderError.captureFailed("menubar.label") }
            let rep = NSBitmapImageRep(cgImage: cgImage)
            let scale = SnapshotExporter.labelScale
            let size = CGSize(width: CGFloat(cgImage.width) / scale, height: CGFloat(cgImage.height) / scale)
            rep.size = size
            guard let png = rep.representation(using: .png, properties: [:]) else { throw RenderError.captureFailed("menubar.label") }
            return RenderedImage(png: png, size: size, scale: Double(scale), rects: [:])
        }

        /// The settings window's content: `SettingsWindowController.rootView(model:)`'s view tree
        /// and environment, with the login item of an installed copy.
        private func settingsContent() -> some View {
            SettingsView()
                .environmentObject(model)
                .environmentObject(model.devices)
                .environmentObject(model.permissions)
                .environmentObject(loginItem)
                .environmentObject(model.settings)
                .environmentObject(model.scroll)
                .environmentObject(model.frontmostMonitor)
        }

        // MARK: Windows

        /// A window that is never ordered in, on the screen with the highest backing scale.
        private static func makeWindow(size: CGSize, appearance: Appearance, titled: Bool) -> NSWindow {
            let screen = NSScreen.screens.max { $0.backingScaleFactor < $1.backingScaleFactor }
            let origin = screen?.frame.origin ?? .zero
            let style: NSWindow.StyleMask = titled
                ? [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
                : [.borderless]
            let window = SnapshotWindow(
                contentRect: NSRect(origin: origin, size: size),
                styleMask: style,
                backing: .buffered,
                defer: false,
                screen: screen
            )
            window.isReleasedWhenClosed = false
            window.appearance = appearance.nsAppearance
            window.animationBehavior = .none
            window.collectionBehavior = [.transient, .ignoresCycle]
            if titled {
                window.title = "Upright"
                window.toolbar = NSToolbar(identifier: "UprightSnapshot")
                window.toolbarStyle = .unified
            } else {
                window.isOpaque = false
                window.backgroundColor = .clear
                window.hasShadow = false
            }
            return window
        }

        private static func dump(_ view: NSView, depth: Int) {
            guard depth < 40 else { return }
            let frame = view.convert(view.bounds, to: nil)
            var extra = ""
            extra += " app=\(view.appearance?.name.rawValue ?? "-") eff=\(view.effectiveAppearance.name.rawValue)"
            if let effect = view as? NSVisualEffectView { extra = " material=\(effect.material.rawValue) blending=\(effect.blendingMode.rawValue) state=\(effect.state.rawValue)" }
            if let popUp = view as? NSPopUpButton { extra = " items=\(popUp.itemTitles)" }
            if String(describing: type(of: view)).contains("Button") {
                var chain: [String] = []
                var cls: AnyClass? = type(of: view)
                while let c = cls { chain.append(NSStringFromClass(c)); cls = class_getSuperclass(c) }
                extra += " chain=\(chain.prefix(5)) menu=\(view.menu?.items.map(\.title) ?? [])"
                if let control = view as? NSControl { extra += " action=\(control.action.map(NSStringFromSelector) ?? "-") target=\(control.target.map { String(describing: type(of: $0)) } ?? "-")" }
            }
            SnapshotExporter.log(String(repeating: "  ", count: depth) + "\(type(of: view)) \(Int(frame.minX)),\(Int(frame.minY)) \(Int(frame.width))x\(Int(frame.height)) hidden=\(view.isHidden) layer=\(view.wantsLayer)" + extra)
            view.subviews.forEach { dump($0, depth: depth + 1) }
        }

        private static func dismantle(_ window: NSWindow) {
            window.contentViewController = nil
            window.contentView = NSView()
            window.close()
        }

        /// Lets SwiftUI and AppKit finish updating and laying out.
        private func layOut(_ window: NSWindow) async {
            // Liquid Glass gives its content a vibrant appearance, whose blending offscreen
            // rendering can't do (text comes out black): plain appearance instead.
            if let root = window.contentView?.superview {
                for glass in Self.glassViews(in: root) {
                    let views = glass.subviews + Self.descendants(of: glass).filter { $0 is NSScrollView || $0 is NSClipView || $0 is NSTableView }
                    for view in views where view.appearance?.name != window.appearance?.name {
                        view.appearance = window.appearance
                    }
                }
            }
            for _ in 0..<3 {
                ActiveAppearance.announce(window)
                window.contentView?.needsLayout = true
                window.layoutIfNeeded()
                window.contentView?.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
                await settle(0.25)
            }
        }

        func settle(_ seconds: Double) async {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        }

        private func waitUntil(timeout: Double = 3, _ condition: @MainActor () -> Bool) async {
            let deadline = Date().addingTimeInterval(timeout)
            while !condition(), Date() < deadline {
                await settle(0.05)
            }
        }

        // MARK: Scrolling

        /// Scrolls the pane's form (the largest scroll view) so the target is in view.
        private func scroll(_ window: NSWindow, to target: State.Scroll) async {
            guard let root = window.contentView, let scrollView = Self.mainScrollView(in: root),
                  let document = scrollView.documentView else { return }
            let clip = scrollView.contentView
            let maxY = max(0, document.frame.height - clip.bounds.height)
            func scroll(toY y: CGFloat) {
                let y = min(max(0, y), maxY)
                let flippedY = document.isFlipped ? y : maxY - y
                clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: flippedY))
                scrollView.reflectScrolledClipView(clip)
            }
            func offset() -> CGFloat {
                document.isFlipped ? clip.bounds.origin.y : maxY - clip.bounds.origin.y
            }
            switch target {
            case .top:
                scroll(toY: 0)
            case .bottom:
                scroll(toY: maxY)
                await layOut(window)
                // Nested scroll views too (the activity log shows its latest lines), twice: the
                // log can still grow while the first scroll settles.
                for _ in 0..<2 {
                    for inner in Self.scrollViews(in: document) {
                        guard let innerDocument = inner.documentView else { continue }
                        let innerClip = inner.contentView
                        let innerMax = max(0, innerDocument.frame.height - innerClip.bounds.height)
                        innerClip.scroll(to: NSPoint(x: innerClip.bounds.origin.x, y: innerDocument.isFlipped ? innerMax : 0))
                        inner.reflectScrolledClipView(innerClip)
                    }
                    await layOut(window)
                }
            case .anchor(let name):
                // Rows are only made when they come into view: step down until the anchor shows,
                // then put it near the top of the visible area.
                let visibleTop = Self.contentTop(of: scrollView, in: root)
                var y: CGFloat = 0
                while SnapshotAnchorCollector.shared.frames[name] == nil, y < maxY {
                    y += clip.bounds.height * 0.5
                    scroll(toY: y)
                    await layOut(window)
                }
                if let frame = SnapshotAnchorCollector.shared.frames[name] {
                    scroll(toY: offset() + frame.minY - visibleTop - 8)
                }
            }
            await layOut(window)
        }

        private static func scrollViews(in root: NSView) -> [NSScrollView] {
            descendants(of: root).compactMap { $0 as? NSScrollView }.filter { !$0.isHidden && $0.bounds.width >= 1 }
        }

        private static func mainScrollView(in root: NSView) -> NSScrollView? {
            scrollViews(in: root).max { a, b in
                let fa = a.convert(a.bounds, to: root), fb = b.convert(b.bounds, to: root)
                return fa.width * fa.height < fb.width * fb.height
            }
        }

        /// Where the scroll view's visible content starts, below the toolbar (top-left origin).
        private static func contentTop(of scrollView: NSScrollView, in root: NSView) -> CGFloat {
            let frame = scrollView.convert(scrollView.bounds, to: root)
            let top = root.isFlipped ? frame.minY : root.bounds.height - frame.maxY
            let toolbar = scrollView.window.map { $0.frame.height - $0.contentLayoutRect.height } ?? 0
            return max(top + scrollView.contentInsets.top, toolbar)
        }

        // MARK: Capture

        private func capture(
            window: NSWindow,
            appearance: Appearance,
            preferenceRects: [String: CGRect],
            panelCornerRadius: CGFloat? = nil
        ) throws -> RenderedImage {
            guard let content = window.contentView else { throw RenderError.captureFailed("no content view") }
            let isPanel = panelCornerRadius != nil
            // The whole window, title bar and toolbar included, unless it is the menu panel.
            let root = isPanel ? content : (content.superview ?? content)
            let size = root.bounds.size
            let scale = SnapshotExporter.defaultScale
            guard size.width >= 1, size.height >= 1, let rep = Self.makeBitmap(size: size, scale: scale) else {
                throw RenderError.captureFailed("bitmap \(size)")
            }
            guard let context = NSGraphicsContext(bitmapImageRep: rep) else { throw RenderError.captureFailed("graphics context") }

            // Offscreen, AppKit can't sample what is behind a window: materials that blend with
            // the desktop are drawn as within-window materials, and Liquid Glass panels (macOS 26)
            // are drawn as a plain panel with their content on top.
            let materials = Self.descendants(of: root).compactMap { $0 as? NSVisualEffectView }
            let savedMaterials = materials.map { ($0, $0.blendingMode, $0.state) }
            for effect in materials {
                effect.blendingMode = .withinWindow
                effect.state = .active
            }
            let glassPanels = Self.glassViews(in: root)
            let titlebars = isPanel ? [] : Self.descendants(of: root).filter { NSStringFromClass(type(of: $0)) == "NSTitlebarContainerView" }
            defer {
                for (effect, blending, state) in savedMaterials {
                    effect.blendingMode = blending
                    effect.state = state
                }
                glassPanels.forEach { $0.isHidden = false }
                titlebars.forEach { $0.isHidden = false }
            }

            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            appearance.nsAppearance.performAsCurrentDrawingAppearance {
                let bounds = NSRect(origin: .zero, size: size)
                let radius = panelCornerRadius ?? Self.windowCornerRadius
                NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).addClip()
                // What the window draws behind its content.
                NSColor.windowBackgroundColor.setFill()
                bounds.fill()

                // 1. Everything but the glass panels and the title bar.
                glassPanels.forEach { $0.isHidden = true }
                titlebars.forEach { $0.isHidden = true }
                Self.draw(root, in: root, scale: scale)

                // 1b. The toolbar's scroll edge: content scrolled under the title bar fades out
                // (on screen it is blurred, which can't be rendered offscreen).
                for titlebar in titlebars {
                    let band = titlebar.convert(titlebar.bounds, to: root)
                    NSColor.windowBackgroundColor.setFill()
                    band.fill()
                    let fade = NSRect(x: band.minX, y: band.minY - 14, width: band.width, height: 14)
                    NSGradient(starting: NSColor.windowBackgroundColor, ending: NSColor.windowBackgroundColor.withAlphaComponent(0))?
                        .draw(in: fade, angle: -90)
                }

                // 2. Each glass panel, then what it holds.
                for glass in glassPanels {
                    glass.isHidden = false
                    Self.drawGlassBackground(glass.convert(glass.bounds, to: root))
                    Self.drawGlassContent(glass, in: root, scale: scale)
                }

                // 3. The title bar (window buttons, title, toolbar) on top.
                for titlebar in titlebars {
                    titlebar.isHidden = false
                    Self.draw(titlebar, in: root, scale: scale)
                }

                // 4. The window's hairline edge, as macOS draws it, so the rounded corners read
                // on a light background in light mode too.
                if !isPanel {
                    let isDark = NSAppearance.currentDrawing().bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                    let edge = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: radius - 0.5, yRadius: radius - 0.5)
                    edge.lineWidth = 1
                    (isDark ? NSColor.white.withAlphaComponent(0.16) : NSColor.black.withAlphaComponent(0.14)).setStroke()
                    edge.stroke()
                }
            }
            NSGraphicsContext.restoreGraphicsState()

            guard let png = rep.representation(using: .png, properties: [:]) else {
                throw RenderError.captureFailed("PNG encoding")
            }

            // Window-space frames from the collector (rows in table cells), else the root's
            // anchor preferences; only those at least partly in the image.
            let contentOffset = root === content ? .zero : Self.offset(of: content, in: root)
            var rects = preferenceRects
            for (name, frame) in SnapshotAnchorCollector.shared.frames {
                rects[name] = frame
            }
            let imageBounds = CGRect(origin: .zero, size: size)
            rects = rects
                .mapValues { $0.offsetBy(dx: contentOffset.x, dy: contentOffset.y) }
                .filter { $0.value.intersects(imageBounds) && $0.value.width > 0 && $0.value.height > 0 }
            return RenderedImage(png: png, size: size, scale: Double(scale), rects: rects)
        }

        /// Window corners: macOS 26 rounds windows with a toolbar more than earlier versions.
        private static var windowCornerRadius: CGFloat {
            if ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 26 { return 16 }
            return 10
        }

        private static func makeBitmap(size: CGSize, scale: CGFloat) -> NSBitmapImageRep? {
            let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: Int((size.width * scale).rounded()),
                pixelsHigh: Int((size.height * scale).rounded()),
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
            )?.retagging(with: .sRGB)
            rep?.size = size
            return rep
        }

        /// Draws `view` (and its subviews) into the current context, where it sits in `root`.
        private static func draw(_ view: NSView, in root: NSView, scale: CGFloat) {
            let size = view.bounds.size
            guard size.width >= 1, size.height >= 1, let rep = makeBitmap(size: size, scale: scale) else { return }
            view.cacheDisplay(in: view.bounds, to: rep)
            let frame = view.convert(view.bounds, to: root)
            rep.draw(in: frame, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: false, hints: nil)
        }

        private static func descendants(of view: NSView) -> [NSView] {
            view.subviews.flatMap { [$0] + descendants(of: $0) }
        }

        /// Liquid Glass views (`NSGlassEffectView`, macOS 26), outermost only.
        private static func glassViews(in root: NSView) -> [NSView] {
            guard let glassClass = NSClassFromString("NSGlassEffectView") else { return [] }
            var found: [NSView] = []
            func visit(_ view: NSView) {
                if view.isKind(of: glassClass), !view.isHidden, view.bounds.width >= 1 {
                    found.append(view)
                    return
                }
                view.subviews.forEach(visit)
            }
            visit(root)
            return found
        }

        /// What a glass panel holds: the visible part of each scroll view in it (a sidebar list),
        /// on top of the panel. Their own backgrounds and the glass's fallback rendering would
        /// cover the panel, so only the document views are drawn. Selected rows get an
        /// accent-colored highlight, which offscreen rendering can't produce.
        private static func drawGlassContent(_ glass: NSView, in root: NSView, scale: CGFloat) {
            let isDark = NSAppearance.currentDrawing().bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let selections = descendants(of: glass).compactMap { $0 as? NSVisualEffectView }
                .filter { $0.material == .selection && !$0.isHidden && $0.bounds.width >= 1 }
            for selection in selections {
                let frame = selection.convert(selection.bounds, to: root)
                NSColor.controlAccentColor.withAlphaComponent(0.2).setFill()
                NSBezierPath(roundedRect: frame, xRadius: 8, yRadius: 8).fill()
                selection.isHidden = true
            }
            defer { selections.forEach { $0.isHidden = false } }
            let scrollViews = descendants(of: glass).compactMap { $0 as? NSScrollView }
            for scrollView in scrollViews where !scrollView.isHidden {
                guard let document = scrollView.documentView else { continue }
                let visible = document.visibleRect
                guard visible.width >= 1, visible.height >= 1, let rep = makeBitmap(size: visible.size, scale: scale) else { continue }
                document.cacheDisplay(in: visible, to: rep)
                if isDark { lightenVibrantText(in: rep) }
                rep.draw(in: document.convert(visible, to: root), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: false, hints: nil)
            }
        }

        /// Sidebar text and symbols are vibrant: their color comes from blending with the glass
        /// behind them, which offscreen rendering skips, so in dark mode they come out black.
        /// Turns those dark, colorless pixels into the light label color they show on screen;
        /// colored icon tiles and their white symbols are left alone.
        private static func lightenVibrantText(in rep: NSBitmapImageRep) {
            guard let data = rep.bitmapData, rep.samplesPerPixel == 4, rep.bitsPerSample == 8, !rep.isPlanar else { return }
            let premultiplied = !rep.bitmapFormat.contains(.alphaNonpremultiplied)
            let alphaFirst = rep.bitmapFormat.contains(.alphaFirst)
            let target: Double = 0.92
            for y in 0..<rep.pixelsHigh {
                let row = data + y * rep.bytesPerRow
                for x in 0..<rep.pixelsWide {
                    let pixel = row + x * 4
                    let (ri, gi, bi, ai) = alphaFirst ? (1, 2, 3, 0) : (0, 1, 2, 3)
                    let alpha = Double(pixel[ai]) / 255
                    guard alpha > 0.02 else { continue }
                    var r = Double(pixel[ri]) / 255, g = Double(pixel[gi]) / 255, b = Double(pixel[bi]) / 255
                    if premultiplied { r /= alpha; g /= alpha; b /= alpha }
                    let high = max(r, g, b), low = min(r, g, b)
                    guard high < 0.35, high - low < 0.08 else { continue }
                    let value = premultiplied ? target * alpha : target
                    let byte = UInt8(max(0, min(255, (value * 255).rounded())))
                    pixel[ri] = byte
                    pixel[gi] = byte
                    pixel[bi] = byte
                }
            }
        }

        /// A glass sidebar as it looks over an empty desktop: a floating rounded panel.
        private static func drawGlassBackground(_ frame: CGRect) {
            let panel = frame.insetBy(dx: 8, dy: 8)
            let path = NSBezierPath(roundedRect: panel, xRadius: 18, yRadius: 18)
            let isDark = NSAppearance.currentDrawing().bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(isDark ? 0.35 : 0.12)
            shadow.shadowBlurRadius = 8
            shadow.shadowOffset = NSSize(width: 0, height: -1)
            shadow.set()
            NSColor(white: isDark ? 0.17 : 0.955, alpha: 1).setFill()
            path.fill()
            NSGraphicsContext.restoreGraphicsState()
            NSColor.separatorColor.withAlphaComponent(0.5).setStroke()
            path.lineWidth = 0.5
            path.stroke()
        }

        /// Where `content` sits in `container`, top-left origin.
        private static func offset(of content: NSView, in container: NSView) -> CGPoint {
            let frame = content.convert(content.bounds, to: container)
            let y = container.isFlipped ? frame.minY : container.bounds.height - frame.maxY
            return CGPoint(x: frame.minX, y: y)
        }
    }

    enum RenderError: Error, CustomStringConvertible {
        case stateNotReached(String)
        case captureFailed(String)

        var description: String {
            switch self {
            case .stateNotReached(let id): return "Could not put the UI into state \(id)"
            case .captureFailed(let detail): return "Capture failed (\(detail))"
            }
        }
    }
}

// MARK: - Active appearance

/// Upright never activates while exporting (that would take focus from the user's app), but an
/// inactive app draws its windows dimmed: grey window buttons, washed-out switches. For this
/// export-only process, `NSApplication.isActive` answers true and each capture window is
/// announced as key, so the images look like the settings window in use.
@MainActor
private enum ActiveAppearance {
    private static var enabled = false

    static func enable() {
        guard !enabled else { return }
        enabled = true
        for selector in [#selector(getter: NSApplication.isActive), NSSelectorFromString("_isActiveApp")] {
            guard let method = class_getInstanceMethod(NSApplication.self, selector) else { continue }
            let alwaysActive: @convention(block) (AnyObject) -> Bool = { _ in true }
            class_replaceMethod(NSApplication.self, selector, imp_implementationWithBlock(alwaysActive), method_getTypeEncoding(method))
        }
        for selector in [#selector(getter: NSApplication.keyWindow), #selector(getter: NSApplication.mainWindow)] {
            guard let method = class_getInstanceMethod(NSApplication.self, selector) else { continue }
            let captureWindow: @convention(block) (AnyObject) -> NSWindow? = { _ in ActiveAppearance.window }
            class_replaceMethod(NSApplication.self, selector, imp_implementationWithBlock(captureWindow), method_getTypeEncoding(method))
        }
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)
    }

    /// The window being captured, which `NSApp.keyWindow` and `mainWindow` report.
    nonisolated(unsafe) private static weak var window: NSWindow?

    static func announce(_ window: NSWindow) {
        self.window = window
        for name in ["acquireKeyAppearance", "acquireMainAppearance"] where window.responds(to: NSSelectorFromString(name)) {
            window.perform(NSSelectorFromString(name))
        }
        NotificationCenter.default.post(name: NSWindow.didBecomeMainNotification, object: window)
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
    }
}

// MARK: - Window

/// The offscreen window draws as the key window would (colored window buttons, accent-colored
/// controls), as the settings window does while the user works in it. It is never ordered in.
private final class SnapshotWindow: NSWindow {
    @objc(_hasActiveAppearance) var hasActiveAppearance: Bool { true }
    @objc(_hasActiveAppearanceIgnoringKeyFocus) var hasActiveAppearanceIgnoringKeyFocus: Bool { true }
    @objc(_hasKeyAppearance) var hasKeyAppearance: Bool { true }
    @objc(_hasMainAppearance) var hasMainAppearance: Bool { true }
    @objc(_hasActiveControls) var hasActiveControls: Bool { true }
    @objc(hasKeyAppearance) var hasKeyAppearancePublic: Bool { true }
    @objc(hasMainAppearance) var hasMainAppearancePublic: Bool { true }
    override var isKeyWindow: Bool { true }
    override var isVisible: Bool { true }
    override var occlusionState: NSWindow.OcclusionState { .visible }
    /// Never shown, so never kept to the screen: a tall pane renders at its full height on
    /// any display.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    override var isMainWindow: Bool { true }
    override var canBecomeKey: Bool { true }
}

// MARK: - Anchor resolution

/// Holds the root's resolved anchor rects for one capture.
@MainActor
private final class RectStore {
    var rects: [String: CGRect] = [:]
}

private struct SnapshotRectsKey: PreferenceKey {
    static var defaultValue: [String: CGRect] { [:] }

    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

/// Resolves every `snapshotAnchor` that reaches the root (its anchor preference) into a rect in
/// the root's coordinates (top-left origin) and keeps them in `store`.
private struct AnchorResolver: ViewModifier {
    let store: RectStore

    func body(content: Content) -> some View {
        content
            .overlayPreferenceValue(SnapshotAnchorKey.self) { anchors in
                GeometryReader { proxy in
                    Color.clear.preference(key: SnapshotRectsKey.self, value: anchors.mapValues { proxy[$0] })
                }
                .allowsHitTesting(false)
            }
            .onPreferenceChange(SnapshotRectsKey.self) { rects in
                MainActorDelivery.run { store.rects = rects }
            }
    }
}

