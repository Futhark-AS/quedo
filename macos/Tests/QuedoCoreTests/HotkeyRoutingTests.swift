import QuedoCore
import XCTest

final class HotkeyRoutingTests: XCTestCase {
    func testToggleModeStartsOnPressedWhenReady() {
        let command = HotkeyRouting.toggleCommand(
            mode: .toggle,
            event: .pressed,
            phase: .ready,
            isRecording: false,
            hasActiveSession: false
        )
        XCTAssertEqual(command, .start)
    }

    func testToggleModeStopsOnPressedWhenRecording() {
        let command = HotkeyRouting.toggleCommand(
            mode: .toggle,
            event: .pressed,
            phase: .recording,
            isRecording: true,
            hasActiveSession: true
        )
        XCTAssertEqual(command, .stop)
    }

    func testToggleModeIgnoresReleaseEdge() {
        let command = HotkeyRouting.toggleCommand(
            mode: .toggle,
            event: .released,
            phase: .recording,
            isRecording: true,
            hasActiveSession: true
        )
        XCTAssertEqual(command, .none)
    }

    func testToggleModeCancelsWhenAudioIsRecovering() {
        let command = HotkeyRouting.toggleCommand(
            mode: .toggle,
            event: .pressed,
            phase: .recoveringAudio,
            isRecording: true,
            hasActiveSession: true
        )
        XCTAssertEqual(command, .cancelArming)
    }

    func testHoldModeStartsOnPressedWhenReady() {
        let command = HotkeyRouting.toggleCommand(
            mode: .hold,
            event: .pressed,
            phase: .ready,
            isRecording: false,
            hasActiveSession: false
        )
        XCTAssertEqual(command, .start)
    }

    func testHoldModeCancelsArmingOnRelease() {
        let command = HotkeyRouting.toggleCommand(
            mode: .hold,
            event: .released,
            phase: .arming,
            isRecording: false,
            hasActiveSession: true
        )
        XCTAssertEqual(command, .cancelArming)
    }

    func testHoldModeStopsOnReleaseWhenRecording() {
        let command = HotkeyRouting.toggleCommand(
            mode: .hold,
            event: .released,
            phase: .recording,
            isRecording: true,
            hasActiveSession: true
        )
        XCTAssertEqual(command, .stop)
    }

    func testHoldModeIgnoresPressedWhenSessionAlreadyActive() {
        let command = HotkeyRouting.toggleCommand(
            mode: .hold,
            event: .pressed,
            phase: .recording,
            isRecording: true,
            hasActiveSession: true
        )
        XCTAssertEqual(command, .none)
    }
}
