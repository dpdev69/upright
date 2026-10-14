import Foundation

/// Everything besides the mappings that decides one endpoint's configuration.
public struct ConfigurationInputs: Hashable, Sendable {
    /// The app-wide "Remap buttons" switch.
    public var remappingEnabled: Bool
    public var accessibilityGranted: Bool
    /// This mouse's own "Remap this mouse" preference.
    public var deviceRemapEnabled: Bool
    /// False for standby, unsupported and pending endpoints (`DeviceRegistry.isActive`, or
    /// `DeviceRegistry.prospectiveRole` for an endpoint that is still connecting).
    public var isActive: Bool
    /// This mouse's pointer speed preference; nil leaves the speed to the mouse.
    public var preferredDPI: Int?
    /// Controls of this device the engine sees held: kept diverted until released.
    public var held: Set<UInt16>
    /// Held controls of this device with a gesture in progress: kept reporting raw movement.
    public var gesturesHeld: Set<UInt16>

    public init(
        remappingEnabled: Bool = true,
        accessibilityGranted: Bool = false,
        deviceRemapEnabled: Bool = true,
        isActive: Bool = true,
        preferredDPI: Int? = nil,
        held: Set<UInt16> = [],
        gesturesHeld: Set<UInt16> = []
    ) {
        self.remappingEnabled = remappingEnabled
        self.accessibilityGranted = accessibilityGranted
        self.deviceRemapEnabled = deviceRemapEnabled
        self.isActive = isActive
        self.preferredDPI = preferredDPI
        self.held = held
        self.gesturesHeld = gesturesHeld
    }
}

/// Decides what one endpoint should be doing. Pure: the same inputs always give the same
/// configuration, so AppModel can compare it with what it last applied.
public enum ConfigurationPlanner {
    /// The configuration for one endpoint.
    ///
    /// - Remapping off: nothing diverted, held buttons included (as Upright 2.x did).
    /// - Inactive endpoint, or "Remap this mouse" off: only held controls stay diverted, so their
    ///   release still arrives; held gestures keep their raw movement. Nothing else is diverted
    ///   and the pointer speed is left alone, so a standby twin with nothing held is `.native`.
    /// - Otherwise: the mapped controls plus the held ones. Gesture controls also report raw
    ///   movement while held, when the control can.
    ///
    /// Diversion is limited to the device's configurable controls, never the primary clicks
    /// (`ControlCatalog.neverDivert`), so mappings made for another model never reach it.
    /// `dpi` is the preferred speed snapped to `dpiInfo`'s supported list; without a list
    /// (unknown device) it is passed through, and the device snaps it when it is applied.
    ///
    /// For an MX Vertical this is exactly what Upright 2.x's `AppModel.syncDiversion` put on the
    /// wire (`ConfigurationPlannerTests.testMatchesTodaysSyncDiversionForMXVertical`).
    public static func configuration(
        mappings: ButtonMappings,
        controls: [ControlInfo],
        dpi dpiInfo: DPIInfo? = nil,
        inputs: ConfigurationInputs
    ) -> EndpointConfiguration {
        let served = inputs.isActive && inputs.deviceRemapEnabled
        let speed = inputs.isActive ? inputs.preferredDPI.map { dpiInfo?.nearest(to: $0) ?? $0 } : nil
        guard inputs.remappingEnabled else { return EndpointConfiguration(dpi: speed) }

        var divert = inputs.held
        var gestures = inputs.gesturesHeld
        if served {
            divert.formUnion(mappings.divertedControls(accessibilityGranted: inputs.accessibilityGranted))
            gestures.formUnion(mappings.gestureControls(accessibilityGranted: inputs.accessibilityGranted))
        }

        let configurable = controls.filter { $0.isConfigurable && !ControlCatalog.neverDivert.contains($0.cid) }
        let configurableCIDs = Set(configurable.map(\.cid))
        let rawCapable = Set(configurable.filter(\.supportsRawXY).map(\.cid))
        return EndpointConfiguration(
            divert: divert.union(gestures).intersection(configurableCIDs),
            rawXY: gestures.intersection(rawCapable),
            dpi: speed
        )
    }

    /// The configuration for a connected endpoint, from its controls and pointer-speed list.
    /// A mouse without ADJUSTABLE_DPI (0x2201) gets no speed.
    public static func configuration(
        mappings: ButtonMappings,
        snapshot: DeviceSnapshot,
        inputs: ConfigurationInputs
    ) -> EndpointConfiguration {
        var configuration = configuration(mappings: mappings, controls: snapshot.controls, dpi: snapshot.dpi, inputs: inputs)
        if snapshot.dpi == nil { configuration.dpi = nil }
        return configuration
    }
}
