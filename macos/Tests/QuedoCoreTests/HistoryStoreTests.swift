import XCTest
@testable import QuedoCore

final class HistoryStoreTests: XCTestCase {
    private func makeTestStore() throws -> HistoryStore {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("quedo-history-test-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }
        return try HistoryStore(baseURL: root)
    }

    func testSaveAndListSession() async throws {
        let store = try makeTestStore()
        let sessionID = UUID()
        let tempAudio = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("history-test-\(sessionID.uuidString).caf")
        try Data("audio".utf8).write(to: tempAudio)

        let record = SessionRecord(
            sessionID: sessionID,
            createdAt: Date(),
            durationMS: 2000,
            providerPrimary: .groq,
            providerUsed: .groq,
            language: "auto",
            outputMode: .clipboard,
            status: .success,
            transcript: "hello world",
            audioPath: tempAudio
        )

        try await store.saveSession(record)
        let sessions = try await store.listSessions(limit: 20)
        XCTAssertTrue(sessions.contains(where: { $0.sessionID == sessionID }))

        let transcript = try await store.transcriptText(sessionID: sessionID)
        XCTAssertEqual(transcript, "hello world")

        let primaryAudio = try await store.primaryAudioFileURL(sessionID: sessionID)
        XCTAssertNotNil(primaryAudio)
        XCTAssertTrue(primaryAudio?.path.contains("/media/\(sessionID.uuidString)/recording.caf") ?? false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: primaryAudio?.path ?? ""))
        let copied = try Data(contentsOf: primaryAudio!)
        XCTAssertEqual(copied, Data("audio".utf8))
    }

    func testPrimaryAudioFileURLReturnsNilWhenMissing() async throws {
        let store = try makeTestStore()
        let missing = try await store.primaryAudioFileURL(sessionID: UUID())
        XCTAssertNil(missing)

        let missingTranscript = try await store.transcriptText(sessionID: UUID())
        XCTAssertNil(missingTranscript)
    }

    func testSaveSessionRemovesTemporarySourceAudio() async throws {
        let store = try makeTestStore()
        let sessionID = UUID()
        let tempAudio = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("history-test-cleanup-\(sessionID.uuidString).wav")
        try Data("audio".utf8).write(to: tempAudio)
        XCTAssertTrue(FileManager.default.fileExists(atPath: tempAudio.path))

        let record = SessionRecord(
            sessionID: sessionID,
            createdAt: Date(),
            durationMS: 1000,
            providerPrimary: .groq,
            providerUsed: .groq,
            language: "en",
            outputMode: .clipboard,
            status: .success,
            transcript: "cleanup",
            audioPath: tempAudio
        )

        try await store.saveSession(record)
        XCTAssertFalse(FileManager.default.fileExists(atPath: tempAudio.path))
    }

    func testDiagnosticEventsSurviveSessionUpsertAndKeepEventTimestamp() async throws {
        let store = try makeTestStore()
        let sessionID = UUID()
        let tempAudio = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("history-test-events-\(sessionID.uuidString).wav")
        try Data("audio".utf8).write(to: tempAudio)

        let eventTime = Date(timeIntervalSince1970: 1234)
        try await store.ensureDiagnosticSession(
            sessionID: sessionID,
            createdAt: eventTime,
            providerPrimary: .openAI,
            language: "en",
            outputMode: .clipboard
        )
        try await store.appendEvent(
            sessionID: sessionID,
            eventName: "session_trace_started",
            payload: ["operation_id": "operation-1"],
            createdAt: eventTime
        )

        let record = SessionRecord(
            sessionID: sessionID,
            createdAt: Date(timeIntervalSince1970: 2000),
            durationMS: 1500,
            providerPrimary: .openAI,
            providerUsed: .openAI,
            language: "en",
            outputMode: .clipboard,
            status: .success,
            transcript: "persisted transcript",
            audioPath: tempAudio
        )
        try await store.saveSession(record)

        let events = try await store.listDiagnosticEvents(limit: 20, sessionID: sessionID)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.eventName, "session_trace_started")
        XCTAssertEqual(events.first?.sessionID, sessionID)
        XCTAssertEqual(events.first?.createdAt, eventTime)
        XCTAssertTrue(events.first?.payloadJSON.contains("operation-1") ?? false)
    }
}
