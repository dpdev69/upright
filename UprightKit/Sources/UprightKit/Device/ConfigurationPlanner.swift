import Foundation

// Wave 0 scaffold: final signatures and a first implementation. W2.2 owns this file and
// proves it golden-equal to today's AppModel.syncDiversion for an MX Vertical.

/// Everything besides the mappings that decides one endpoint's configuration.
public struct ConfigurationInputs: Hashable, Sendable {
    /// The app-wide "Remap buttons" switch.
    public var remappingEnabled: Bool
    public var accessibilityGranted: Bool
    /// This mouse's own "Remap this mouse" preference.
    public var deviceRemapEnabled: Bool
    /// False for standby, unsupported and pending endpoints (`DeviceRegistry.isActive`).
    public var isActive: Bool
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

public enum ConfigurationPlanner {
    /// The configuration for one endpoint.
    ///
    /// - Remapping off: nothing diverted.
    /// - Inactive endpoint or "Remap this mouse" off: only held controls stay diverted (so their
    ///   release still arrives), held gestures keep raw movement.
    /// - Otherwise: the mapped controls plus held ones; gesture controls also report raw XY
    ///   when the control can.
    ///
    /// Diversion is limited to the device's configurable controls (never the primary clicks).
    /// `dpi` snaps the preferred speed to what the device supports; without it the value is
    /// passed through.
    public static func configuration(
        mappings: ButtonMappings,
        controls: [ControlInfo],
        dpi: DPIInfo? = nil,
        inputs: ConfigurationInputs
    ) -> EndpointConfiguration {
        let speed = inputs.preferredDPI.map { dpi?.nearest(to: $0) ?? $0 }
        guard inputs.remappingEnabled else { return EndpointConfiguration(dpi: speed) }

        let divert: Set<UInt16>
        let gestures: Set<UInt16>
        if inputs.isActive && inputs.deviceRemapEnabled {
            divert = mappings.divertedControls(accessibilityGranted: inputs.accessibilityGranted).union(inputs.held)
            gestures = mappings.gestureControls(accessibilityGranted: inputs.accessibilityGranted).union(inputs.gesturesHeld)
        } else {
            divert = inputs.held
            gestures = inputs.gesturesHeld
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
}
