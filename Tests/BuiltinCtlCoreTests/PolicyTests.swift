import XCTest
@testable import BuiltinCtlCore

final class PolicyTests: XCTestCase {
    func testPausesWhenTrackedExternalIsOnlineButAsleep() {
        XCTAssertTrue(
            shouldPauseForSleepingExternal(
                activeExternalIDs: [],
                trackedExternalIDs: [3],
                sleepingExternalIDs: [3]
            )
        )
    }

    func testDoesNotConfusePhysicalRemovalWithDisplaySleep() {
        XCTAssertFalse(
            shouldPauseForSleepingExternal(
                activeExternalIDs: [],
                trackedExternalIDs: [3],
                sleepingExternalIDs: []
            )
        )
        XCTAssertFalse(
            shouldPauseForSleepingExternal(
                activeExternalIDs: [4],
                trackedExternalIDs: [3, 4],
                sleepingExternalIDs: [3]
            )
        )
    }

    private let safe = TopologyState(
        builtinFound: true, builtinActive: true, activeExternalCount: 1,
        automationArmed: true, suspended: false, topologyValid: true
    )

    func testDisablesOnlyWhenEveryConditionIsSafe() {
        XCTAssertEqual(desiredState(for: safe), .disabled)
    }

    func testFailOpenConditions() {
        var states: [TopologyState] = []
        var state = safe; state.suspended = true; states.append(state)
        state = safe; state.automationArmed = false; states.append(state)
        state = safe; state.topologyValid = false; states.append(state)
        state = safe; state.builtinFound = false; states.append(state)
        state = safe; state.activeExternalCount = 0; states.append(state)
        for state in states { XCTAssertEqual(desiredState(for: state), .enabled) }
    }

    func testClosedLidLeavesDisplayOwnershipToMacOS() {
        var state = safe
        state.lidClosed = true
        XCTAssertEqual(desiredState(for: state), .unchanged)

        state.activeExternalCount = 0
        state.builtinActive = false
        XCTAssertEqual(desiredState(for: state), .unchanged)
    }
}
