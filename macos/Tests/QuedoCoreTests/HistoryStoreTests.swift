import XCTest
@testable import QuedoCore

final class HistoryStoreTests: XCTestCase {
    func testSaveAndListSession() async throws {
        let store = try makeIsolatedHistoryStore()
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
        let store = try makeIsolatedHistoryStore()
        let missing = try await store.primaryAudioFileURL(sessionID: UUID())
        XCTAssertNil(missing)

        let missingTranscript = try await store.transcriptText(sessionID: UUID())
        XCTAssertNil(missingTranscript)
    }

    func testSaveSessionRemovesTemporarySourceAudio() async throws {
        let store = try makeIsolatedHistoryStore()
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

    private func makeIsolatedHistoryStore() throws -> HistoryStore {
        let baseURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("quedo-history-test-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: baseURL)
        }
        return try HistoryStore(baseURL: baseURL)
    }
}
