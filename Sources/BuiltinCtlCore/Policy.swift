public enum DesiredBuiltinState: Equatable {
    case enabled
    case disabled
}

public struct TopologyState: Equatable {
    public var builtinFound: Bool
    public var builtinActive: Bool
    public var activeExternalCount: Int
    public var automationArmed: Bool
    public var suspended: Bool
    public var topologyValid: Bool

    public init(
        builtinFound: Bool,
        builtinActive: Bool,
        activeExternalCount: Int,
        automationArmed: Bool,
        suspended: Bool,
        topologyValid: Bool
    ) {
        self.builtinFound = builtinFound
        self.builtinActive = builtinActive
        self.activeExternalCount = activeExternalCount
        self.automationArmed = automationArmed
        self.suspended = suspended
        self.topologyValid = topologyValid
    }
}

/// Fail-open policy: every uncertain or unarmed state requests an enabled panel.
public func desiredState(for state: TopologyState) -> DesiredBuiltinState {
    guard !state.suspended,
          state.automationArmed,
          state.topologyValid,
          state.builtinFound,
          state.activeExternalCount > 0 else {
        return .enabled
    }
    return .disabled
}

/// A sleeping display temporarily leaves the active list without being
/// physically disconnected. Pause only when all active externals disappeared
/// and at least one external involved in the prior disable remains online and
/// is explicitly reported asleep by CoreGraphics.
public func shouldPauseForSleepingExternal(
    activeExternalIDs: Set<UInt32>,
    trackedExternalIDs: Set<UInt32>,
    sleepingExternalIDs: Set<UInt32>
) -> Bool {
    activeExternalIDs.isEmpty
        && !trackedExternalIDs.isEmpty
        && !trackedExternalIDs.isDisjoint(with: sleepingExternalIDs)
}
