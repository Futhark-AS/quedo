import XCTest
@testable import QuedoCore

final class StateMachineTests: XCTestCase {
    func testBootingToReadyTransition() async throws {
        let machine = LifecycleStateMachine()
        try await machine.transition(to: .ready)
        let snapshot = await machine.snapshot()
        XCTAssertEqual(snapshot.phase, .ready)
    }

    func testReadyToArmingRequiresActiveSession() async throws {
        let machine = LifecycleStateMachine()
        try await machine.transition(to: .ready)

        do {
            try await machine.transition(to: .arming)
            XCTFail("Transition should fail without active session")
        } catch {
            XCTAssertTrue(error is StateTransitionError)
        }

        let sessionID = UUID()
        try await machine.beginSession(id: sessionID)
        try await machine.transition(to: .arming)
        let snapshot = await machine.snapshot()
        XCTAssertEqual(snapshot.phase, .arming)
        XCTAssertEqual(snapshot.currentSessionID, sessionID)
    }

    func testRetryAvailableToProcessingTransition() async throws {
        let machine = LifecycleStateMachine()
        try await machine.transition(to: .ready)
        try await machine.transition(to: .degraded, degradedReason: .providerUnavailable)
        try await machine.transition(to: .ready)

        try await machine.beginSession(id: UUID())
        try await machine.transition(to: .arming)
        try await machine.transition(to: .recording)
        try await machine.transition(to: .processing)
        try await machine.transition(to: .providerFallback)
        try await machine.transition(to: .retryAvailable)

        try await machine.transition(to: .processing)
        let snapshot = await machine.snapshot()
        XCTAssertEqual(snapshot.phase, .processing)
    }

    func testProcessingToRetryAvailableTransition() async throws {
        let machine = LifecycleStateMachine()
        try await machine.transition(to: .ready)
        try await machine.beginSession(id: UUID())
        try await machine.transition(to: .arming)
        try await machine.transition(to: .recording)
        try await machine.transition(to: .processing)
        try await machine.transition(to: .retryAvailable)

        let snapshot = await machine.snapshot()
        XCTAssertEqual(snapshot.phase, .retryAvailable)
    }

    func testActivePhasesCanTransitionBackToReady() async throws {
        let arming = LifecycleStateMachine()
        try await arming.transition(to: .ready)
        try await arming.beginSession(id: UUID())
        try await arming.transition(to: .arming)
        try await arming.transition(to: .ready)
        let armingSnapshot = await arming.snapshot()
        XCTAssertEqual(armingSnapshot.phase, .ready)

        let recording = LifecycleStateMachine()
        try await recording.transition(to: .ready)
        try await recording.beginSession(id: UUID())
        try await recording.transition(to: .arming)
        try await recording.transition(to: .recording)
        try await recording.transition(to: .ready)
        let recordingSnapshot = await recording.snapshot()
        XCTAssertEqual(recordingSnapshot.phase, .ready)

        let processing = LifecycleStateMachine()
        try await processing.transition(to: .ready)
        try await processing.beginSession(id: UUID())
        try await processing.transition(to: .arming)
        try await processing.transition(to: .recording)
        try await processing.transition(to: .processing)
        try await processing.transition(to: .ready)
        let processingSnapshot = await processing.snapshot()
        XCTAssertEqual(processingSnapshot.phase, .ready)

        let fallback = LifecycleStateMachine()
        try await fallback.transition(to: .ready)
        try await fallback.beginSession(id: UUID())
        try await fallback.transition(to: .arming)
        try await fallback.transition(to: .recording)
        try await fallback.transition(to: .processing)
        try await fallback.transition(to: .providerFallback)
        try await fallback.transition(to: .ready)
        let fallbackSnapshot = await fallback.snapshot()
        XCTAssertEqual(fallbackSnapshot.phase, .ready)

        let retry = LifecycleStateMachine()
        try await retry.transition(to: .ready)
        try await retry.beginSession(id: UUID())
        try await retry.transition(to: .arming)
        try await retry.transition(to: .recording)
        try await retry.transition(to: .processing)
        try await retry.transition(to: .providerFallback)
        try await retry.transition(to: .retryAvailable)
        try await retry.transition(to: .ready)
        let retrySnapshot = await retry.snapshot()
        XCTAssertEqual(retrySnapshot.phase, .ready)
    }

    func testUIContractForPermissionsDegradedState() async {
        let contract = LifecycleStateMachine.uiContract(for: .degraded, degradedReason: .permissions)
        XCTAssertEqual(contract.icon, "shield")
        XCTAssertEqual(contract.notificationCopy, "Permission needed for full functionality.")
        XCTAssertTrue(contract.actions.contains(.openSettings))
    }

    func testReadyContractIncludesPlaybackAction() async {
        let contract = LifecycleStateMachine.uiContract(for: .ready, degradedReason: nil)
        XCTAssertTrue(contract.actions.contains(.history))
        XCTAssertTrue(contract.actions.contains(.playLastRecording))
    }
}
