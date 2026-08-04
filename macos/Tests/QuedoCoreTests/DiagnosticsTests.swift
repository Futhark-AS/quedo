import XCTest
@testable import QuedoCore

final class DiagnosticsTests: XCTestCase {
    func testProviderDiagnosticAttributesDoNotContainTerminalResponseBody() {
        let error = ProviderError.terminal(statusCode: 401, message: "secret response body")

        XCTAssertEqual(error.diagnosticCode, "terminal")
        XCTAssertEqual(error.diagnosticAttributes["status_code"], "401")
        XCTAssertNil(error.diagnosticAttributes["message"])
        XCTAssertFalse(error.diagnosticAttributes.values.contains { $0.contains("secret") })
    }

    func testRuntimeSnapshotRoundTripsWithCorrelationFields() throws {
        let sessionID = UUID()
        let operationID = UUID()
        let snapshot = RuntimeDiagnosticsSnapshot(
            status: "stalled",
            sessionID: sessionID,
            operationID: operationID,
            phase: "processing",
            stage: "provider_chunk_started",
            sessionStartedAt: Date(timeIntervalSince1970: 100),
            lastProgressAt: Date(timeIntervalSince1970: 110),
            details: ["provider": "groq"]
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let decoded = try decoder.decode(RuntimeDiagnosticsSnapshot.self, from: encoder.encode(snapshot))
        XCTAssertEqual(decoded.status, "stalled")
        XCTAssertEqual(decoded.sessionID, sessionID)
        XCTAssertEqual(decoded.operationID, operationID)
        XCTAssertEqual(decoded.phase, "processing")
        XCTAssertEqual(decoded.stage, "provider_chunk_started")
        XCTAssertEqual(decoded.details["provider"], "groq")
    }

    func testMetricPointCarriesSessionAndOperationCorrelation() {
        let sessionID = UUID()
        let operationID = UUID()
        let point = MetricPoint(
            name: "session_failed_total",
            value: 1,
            tags: ["stage": "output"],
            sessionID: sessionID,
            operationID: operationID
        )

        XCTAssertEqual(point.sessionID, sessionID)
        XCTAssertEqual(point.operationID, operationID)
    }

    func testStaleSessionProgressCannotOverwriteNewerTrace() async throws {
        let testRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("quedo-diagnostics-test-\(UUID().uuidString)", isDirectory: true)

        do {
            let store = try HistoryStore(baseURL: testRoot)
            let logger = AppLogger(
                subsystem: "com.futhark.quedo.tests",
                category: "diagnostics",
                fileLogger: RotatingFileLogger(directory: testRoot.appendingPathComponent("logs", isDirectory: true))
            )
            let diagnostics = DiagnosticsCenter(historyStore: store, logger: logger)
            let firstSessionID = UUID()
            let firstOperationID = UUID()
            let secondSessionID = UUID()
            let secondOperationID = UUID()

            await diagnostics.beginSessionTrace(
                sessionID: firstSessionID,
                operationID: firstOperationID,
                phase: "processing",
                stage: "first_started"
            )
            await diagnostics.beginSessionTrace(
                sessionID: secondSessionID,
                operationID: secondOperationID,
                phase: "processing",
                stage: "second_started"
            )
            await diagnostics.markSessionProgress(
                sessionID: firstSessionID,
                operationID: firstOperationID,
                phase: "processing",
                stage: "stale_update"
            )
            await diagnostics.endSessionTrace(
                sessionID: firstSessionID,
                operationID: firstOperationID,
                outcome: "failed",
                phase: "failed",
                stage: "stale_end"
            )

            let snapshot = await diagnostics.runtimeSnapshot()
            XCTAssertEqual(snapshot.sessionID, secondSessionID)
            XCTAssertEqual(snapshot.operationID, secondOperationID)
            XCTAssertEqual(snapshot.stage, "second_started")
            await diagnostics.endSessionTrace(
                sessionID: secondSessionID,
                operationID: secondOperationID,
                outcome: "success",
                phase: "ready",
                stage: "test_completed"
            )
            await diagnostics.shutdown()
        }

        try? FileManager.default.removeItem(at: testRoot)
    }
}
