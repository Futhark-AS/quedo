import CryptoKit
import Foundation
import SQLite3

/// Errors returned by history persistence.
public enum HistoryStoreError: Error, Sendable {
    /// Database initialization failed.
    case databaseOpenFailed
    /// SQL statement failed.
    case sqlError(message: String)
    /// Legacy migration source does not exist.
    case legacySourceMissing
    /// No transcript row exists for the given session.
    case transcriptNotFound
}

/// Lightweight history list row.
public struct HistorySessionSummary: Sendable {
    /// Session identifier.
    public let sessionID: UUID
    /// Creation timestamp.
    public let createdAt: Date
    /// Duration in milliseconds.
    public let durationMS: Int
    /// Provider used for output.
    public let providerUsed: ProviderKind
    /// Final session status.
    public let status: SessionStatus
    /// Transcript preview.
    public let transcriptPreview: String

    /// Creates a summary row.
    public init(
        sessionID: UUID,
        createdAt: Date,
        durationMS: Int,
        providerUsed: ProviderKind,
        status: SessionStatus,
        transcriptPreview: String
    ) {
        self.sessionID = sessionID
        self.createdAt = createdAt
        self.durationMS = durationMS
        self.providerUsed = providerUsed
        self.status = status
        self.transcriptPreview = transcriptPreview
    }
}

/// Migration summary for legacy Python imports.
public struct LegacyMigrationReport: Sendable {
    /// Number of legacy folders scanned.
    public let scanned: Int
    /// Number of migrated sessions inserted or updated.
    public let migrated: Int
    /// Number of entries skipped due to missing media.
    public let skipped: Int

    /// Creates migration report.
    public init(scanned: Int, migrated: Int, skipped: Int) {
        self.scanned = scanned
        self.migrated = migrated
        self.skipped = skipped
    }
}

/// SQLite-backed session history and migration store.
public actor HistoryStore {
    private let fileManager: FileManager
    private let baseURL: URL
    private let dbURL: URL
    private let recoveredDatabaseFromCorruption: Bool
    private var db: OpaquePointer?

    /// Creates history store and initializes schema.
    public init(fileManager: FileManager = .default, baseURL: URL? = nil) throws {
        let resolvedBaseURL = baseURL ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Quedo", isDirectory: true)
        let resolvedDBURL = resolvedBaseURL.appendingPathComponent("db/history.sqlite")

        self.fileManager = fileManager
        self.baseURL = resolvedBaseURL
        self.dbURL = resolvedDBURL

        try Self.setupDirectories(fileManager: fileManager, baseURL: resolvedBaseURL)
        let openResult = try Self.openOrRecoverDatabase(at: resolvedDBURL, fileManager: fileManager)
        let connection = openResult.connection
        self.recoveredDatabaseFromCorruption = openResult.recoveredFromCorruption
        self.db = connection
    }

    /// Indicates startup recovered from a corrupted on-disk database.
    public func recoveredDatabaseOnStartup() -> Bool {
        recoveredDatabaseFromCorruption
    }

    /// Stores a completed session and related artifacts.
    public func saveSession(
        _ session: SessionRecord,
        legacySourcePath: String? = nil,
        legacyAudioFormat: String? = nil
    ) throws {
        let persistedAudioPath = try persistAudioArtifact(sessionID: session.sessionID, sourcePath: session.audioPath)

        try execute("BEGIN IMMEDIATE TRANSACTION")
        do {
            let insertSession = try prepare(
                """
                INSERT OR REPLACE INTO sessions (
                    session_id,
                    created_at,
                    duration_ms,
                    provider_primary,
                    provider_used,
                    language,
                    output_mode,
                    status,
                    legacy_source_path,
                    legacy_audio_format
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
                """
            )
            defer { sqlite3_finalize(insertSession) }

            bindText(session.sessionID.uuidString, to: 1, in: insertSession)
            bindDouble(session.createdAt.timeIntervalSince1970, to: 2, in: insertSession)
            bindInt32(Int32(session.durationMS), to: 3, in: insertSession)
            bindText(session.providerPrimary.rawValue, to: 4, in: insertSession)
            bindText(session.providerUsed.rawValue, to: 5, in: insertSession)
            bindText(session.language, to: 6, in: insertSession)
            bindText(session.outputMode.rawValue, to: 7, in: insertSession)
            bindText(session.status.rawValue, to: 8, in: insertSession)
            bindOptionalText(legacySourcePath, to: 9, in: insertSession)
            bindOptionalText(legacyAudioFormat, to: 10, in: insertSession)
            try stepDone(insertSession)

            let mediaStatement = try prepare(
                """
                INSERT OR REPLACE INTO session_media (
                    id,
                    session_id,
                    media_type,
                    file_path,
                    is_primary
                ) VALUES (?, ?, ?, ?, ?);
                """
            )
            defer { sqlite3_finalize(mediaStatement) }

            bindText(UUID().uuidString, to: 1, in: mediaStatement)
            bindText(session.sessionID.uuidString, to: 2, in: mediaStatement)
            bindText("audio", to: 3, in: mediaStatement)
            bindText(persistedAudioPath.path, to: 4, in: mediaStatement)
            bindInt32(1, to: 5, in: mediaStatement)
            try stepDone(mediaStatement)

            let transcriptStatement = try prepare(
                """
                INSERT OR REPLACE INTO session_transcripts (
                    id,
                    session_id,
                    transcript_text,
                    created_at
                ) VALUES (?, ?, ?, ?);
                """
            )
            defer { sqlite3_finalize(transcriptStatement) }

            bindText(UUID().uuidString, to: 1, in: transcriptStatement)
            bindText(session.sessionID.uuidString, to: 2, in: transcriptStatement)
            bindText(session.transcript, to: 3, in: transcriptStatement)
            bindDouble(Date().timeIntervalSince1970, to: 4, in: transcriptStatement)
            try stepDone(transcriptStatement)

            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    /// Appends a structured session event entry.
    public func appendEvent(sessionID: UUID?, eventName: String, payload: [String: String]) throws {
        let statement = try prepare(
            """
            INSERT INTO session_events (
                id,
                session_id,
                event_name,
                payload_json,
                created_at,
                event_seq
            ) VALUES (?, ?, ?, ?, ?, ?);
            """
        )
        defer { sqlite3_finalize(statement) }

        let jsonData = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        let jsonString = String(data: jsonData, encoding: .utf8) ?? "{}"

        bindText(UUID().uuidString, to: 1, in: statement)
        bindOptionalText(sessionID?.uuidString, to: 2, in: statement)
        bindText(eventName, to: 3, in: statement)
        bindText(jsonString, to: 4, in: statement)
        bindDouble(Date().timeIntervalSince1970, to: 5, in: statement)
        bindInt64(nextEventSequence(sessionID: sessionID), to: 6, in: statement)
        try stepDone(statement)
    }

    /// Returns latest session rows.
    public func listSessions(limit: Int = 50) throws -> [HistorySessionSummary] {
        let statement = try prepare(
            """
            SELECT s.session_id, s.created_at, s.duration_ms, s.provider_used, s.status,
                   COALESCE(t.transcript_text, '')
            FROM sessions s
            LEFT JOIN session_transcripts t ON t.session_id = s.session_id
                AND t.id = (
                    SELECT id FROM session_transcripts
                    WHERE session_id = s.session_id
                    ORDER BY created_at DESC
                    LIMIT 1
                )
            ORDER BY s.created_at DESC
            LIMIT ?;
            """
        )
        defer { sqlite3_finalize(statement) }

        bindInt32(Int32(limit), to: 1, in: statement)

        var result: [HistorySessionSummary] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard
                let sessionCString = sqlite3_column_text(statement, 0),
                let providerCString = sqlite3_column_text(statement, 3),
                let statusCString = sqlite3_column_text(statement, 4)
            else {
                continue
            }

            let sessionID = UUID(uuidString: String(cString: sessionCString))
            let createdAt = sqlite3_column_double(statement, 1)
            let duration = sqlite3_column_int(statement, 2)
            let provider = String(cString: providerCString)
            let status = String(cString: statusCString)
            let transcript = sqlite3_column_text(statement, 5).map { String(cString: $0) } ?? ""

            guard
                let sessionID,
                let providerKind = ProviderKind(rawValue: provider),
                let sessionStatus = SessionStatus(rawValue: status)
            else {
                continue
            }

            result.append(
                HistorySessionSummary(
                    sessionID: sessionID,
                    createdAt: Date(timeIntervalSince1970: createdAt),
                    durationMS: Int(duration),
                    providerUsed: providerKind,
                    status: sessionStatus,
                    transcriptPreview: String(transcript.prefix(120))
                )
            )
        }

        return result
    }

    /// Returns full transcript text for a session when available.
    public func transcriptText(sessionID: UUID) throws -> String? {
        let statement = try prepare(
            """
            SELECT transcript_text
            FROM session_transcripts
            WHERE session_id = ?
            ORDER BY created_at DESC
            LIMIT 1;
            """
        )
        defer { sqlite3_finalize(statement) }

        bindText(sessionID.uuidString, to: 1, in: statement)
        guard sqlite3_step(statement) == SQLITE_ROW else {
            return nil
        }

        return sqlite3_column_text(statement, 0).map { String(cString: $0) } ?? ""
    }

    /// Replaces the transcript text for a session.
    public func updateTranscript(sessionID: UUID, text: String) throws {
        let statement = try prepare(
            """
            UPDATE session_transcripts
            SET transcript_text = ?, created_at = ?
            WHERE session_id = ?
            AND id = (
                SELECT id FROM session_transcripts
                WHERE session_id = ?
                ORDER BY created_at DESC
                LIMIT 1
            );
            """
        )
        defer { sqlite3_finalize(statement) }

        bindText(text, to: 1, in: statement)
        bindDouble(Date().timeIntervalSince1970, to: 2, in: statement)
        bindText(sessionID.uuidString, to: 3, in: statement)
        bindText(sessionID.uuidString, to: 4, in: statement)
        try stepDone(statement)

        guard sqlite3_changes(db) > 0 else {
            throw HistoryStoreError.transcriptNotFound
        }
    }

    /// Returns the primary audio media file URL for a session when available.
    public func primaryAudioFileURL(sessionID: UUID) throws -> URL? {
        let statement = try prepare(
            """
            SELECT file_path
            FROM session_media
            WHERE session_id = ? AND media_type = 'audio'
            ORDER BY is_primary DESC, rowid DESC
            LIMIT 1;
            """
        )
        defer { sqlite3_finalize(statement) }

        bindText(sessionID.uuidString, to: 1, in: statement)
        guard sqlite3_step(statement) == SQLITE_ROW, let cString = sqlite3_column_text(statement, 0) else {
            return nil
        }

        return URL(fileURLWithPath: String(cString: cString))
    }

    /// Migrates legacy Python history folders into SQLite and media layout.
    public func migrateLegacyPythonHistory() throws -> LegacyMigrationReport {
        let source = legacyHistorySource()
        guard fileManager.fileExists(atPath: source.path) else {
            throw HistoryStoreError.legacySourceMissing
        }

        let mediaRoot = baseURL.appendingPathComponent("media", isDirectory: true)
        try fileManager.createDirectory(at: mediaRoot, withIntermediateDirectories: true)

        let dateFolders = try fileManager.contentsOfDirectory(at: source, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
            .filter { $0.lastPathComponent.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil }

        var scanned = 0
        var migrated = 0
        var skipped = 0

        for dateFolder in dateFolders {
            let timeFolders = try fileManager.contentsOfDirectory(at: dateFolder, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
                .filter { $0.lastPathComponent.range(of: #"^\d{6}$"#, options: .regularExpression) != nil }

            for timeFolder in timeFolders {
                scanned += 1
                let flac = timeFolder.appendingPathComponent("recording.flac")
                let wav = timeFolder.appendingPathComponent("recording.wav")
                let transcriptFile = timeFolder.appendingPathComponent("transcription.txt")

                let hasFLAC = fileManager.fileExists(atPath: flac.path)
                let hasWAV = fileManager.fileExists(atPath: wav.path)

                guard hasFLAC || hasWAV else {
                    skipped += 1
                    continue
                }

                let deterministicID = deterministicSessionID(forLegacyPath: timeFolder.path)
                let sessionMedia = mediaRoot.appendingPathComponent(deterministicID.uuidString, isDirectory: true)
                try fileManager.createDirectory(at: sessionMedia, withIntermediateDirectories: true)

                let primarySource: URL = hasFLAC ? flac : wav
                let primaryExtension = hasFLAC ? "flac" : "wav"
                let primaryDestination = sessionMedia.appendingPathComponent("recording.\(primaryExtension)")
                if !fileManager.fileExists(atPath: primaryDestination.path) {
                    try fileManager.copyItem(at: primarySource, to: primaryDestination)
                }

                if hasFLAC && hasWAV {
                    let secondaryDestination = sessionMedia.appendingPathComponent("recording-secondary.wav")
                    if !fileManager.fileExists(atPath: secondaryDestination.path) {
                        try fileManager.copyItem(at: wav, to: secondaryDestination)
                    }
                }

                let transcript = (try? String(contentsOf: transcriptFile, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let createdAt = parseLegacyDate(date: dateFolder.lastPathComponent, time: timeFolder.lastPathComponent)

                let record = SessionRecord(
                    sessionID: deterministicID,
                    createdAt: createdAt,
                    durationMS: 0,
                    providerPrimary: .groq,
                    providerUsed: .groq,
                    language: "auto",
                    outputMode: .clipboard,
                    status: .success,
                    transcript: transcript,
                    audioPath: primaryDestination
                )

                try saveSession(record, legacySourcePath: timeFolder.path, legacyAudioFormat: primaryExtension)
                try appendEvent(
                    sessionID: deterministicID,
                    eventName: "migration_event",
                    payload: [
                        "source": timeFolder.path,
                        "result": "imported",
                        "primary_format": primaryExtension
                    ]
                )

                if hasFLAC && hasWAV {
                    let stmt = try prepare(
                        """
                        INSERT OR REPLACE INTO session_media (id, session_id, media_type, file_path, is_primary)
                        VALUES (?, ?, ?, ?, ?);
                        """
                    )
                    bindText(UUID().uuidString, to: 1, in: stmt)
                    bindText(deterministicID.uuidString, to: 2, in: stmt)
                    bindText("audio", to: 3, in: stmt)
                    bindText(sessionMedia.appendingPathComponent("recording-secondary.wav").path, to: 4, in: stmt)
                    bindInt32(0, to: 5, in: stmt)
                    try stepDone(stmt)
                    sqlite3_finalize(stmt)
                }

                migrated += 1
            }
        }

        return LegacyMigrationReport(scanned: scanned, migrated: migrated, skipped: skipped)
    }

    /// Returns app support base path used by history store.
    public func storageBasePath() -> URL {
        baseURL
    }

    private static func setupDirectories(fileManager: FileManager, baseURL: URL) throws {
        try fileManager.createDirectory(at: baseURL.appendingPathComponent("db"), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: baseURL.appendingPathComponent("media"), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: baseURL.appendingPathComponent("logs"), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: baseURL.appendingPathComponent("exports"), withIntermediateDirectories: true)
    }

    private static func openOrRecoverDatabase(
        at dbURL: URL,
        fileManager: FileManager
    ) throws -> (connection: OpaquePointer, recoveredFromCorruption: Bool) {
        do {
            let connection = try openInitializedDatabase(at: dbURL)
            return (connection, false)
        } catch {
            try quarantineDatabaseFiles(at: dbURL, fileManager: fileManager)
            let connection = try openInitializedDatabase(at: dbURL)
            return (connection, true)
        }
    }

    private static func openInitializedDatabase(at dbURL: URL) throws -> OpaquePointer {
        let connection = try openDatabase(at: dbURL)
        do {
            try initializeSchema(on: connection)
            return connection
        } catch {
            sqlite3_close(connection)
            throw error
        }
    }

    private static func openDatabase(at dbURL: URL) throws -> OpaquePointer {
        var connection: OpaquePointer?
        let status = sqlite3_open_v2(
            dbURL.path,
            &connection,
            SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        )

        guard status == SQLITE_OK, let connection else {
            throw HistoryStoreError.databaseOpenFailed
        }

        do {
            try executeSQL("PRAGMA journal_mode=WAL;", on: connection)
            try executeSQL("PRAGMA synchronous=NORMAL;", on: connection)
            try executeSQL("PRAGMA foreign_keys=ON;", on: connection)
            return connection
        } catch {
            sqlite3_close(connection)
            throw error
        }
    }

    private static func quarantineDatabaseFiles(at dbURL: URL, fileManager: FileManager) throws {
        let timestamp = Int(Date().timeIntervalSince1970)
        let suffixes = ["", "-wal", "-shm"]

        for suffix in suffixes {
            let sourcePath = dbURL.path + suffix
            guard fileManager.fileExists(atPath: sourcePath) else {
                continue
            }

            let sourceURL = URL(fileURLWithPath: sourcePath)
            var destinationURL = dbURL
                .deletingLastPathComponent()
                .appendingPathComponent("\(dbURL.lastPathComponent).corrupt-\(timestamp)\(suffix)")

            if fileManager.fileExists(atPath: destinationURL.path) {
                destinationURL = dbURL
                    .deletingLastPathComponent()
                    .appendingPathComponent("\(dbURL.lastPathComponent).corrupt-\(timestamp)-\(UUID().uuidString)\(suffix)")
            }

            try fileManager.moveItem(at: sourceURL, to: destinationURL)
        }
    }

    private static func initializeSchema(on db: OpaquePointer) throws {
        try executeSQL(
            """
            CREATE TABLE IF NOT EXISTS schema_migrations (
                version TEXT PRIMARY KEY,
                applied_at REAL NOT NULL
            );

            CREATE TABLE IF NOT EXISTS sessions (
                session_id TEXT PRIMARY KEY,
                created_at REAL NOT NULL,
                duration_ms INTEGER NOT NULL,
                provider_primary TEXT NOT NULL,
                provider_used TEXT NOT NULL,
                language TEXT NOT NULL,
                output_mode TEXT NOT NULL,
                status TEXT NOT NULL,
                legacy_source_path TEXT,
                legacy_audio_format TEXT
            );

            CREATE TABLE IF NOT EXISTS session_media (
                id TEXT PRIMARY KEY,
                session_id TEXT NOT NULL,
                media_type TEXT NOT NULL,
                file_path TEXT NOT NULL,
                is_primary INTEGER NOT NULL,
                FOREIGN KEY(session_id) REFERENCES sessions(session_id) ON DELETE CASCADE
            );

            CREATE TABLE IF NOT EXISTS session_transcripts (
                id TEXT PRIMARY KEY,
                session_id TEXT NOT NULL,
                transcript_text TEXT NOT NULL,
                created_at REAL NOT NULL,
                FOREIGN KEY(session_id) REFERENCES sessions(session_id) ON DELETE CASCADE
            );

            CREATE TABLE IF NOT EXISTS session_events (
                id TEXT PRIMARY KEY,
                session_id TEXT,
                event_name TEXT NOT NULL,
                payload_json TEXT NOT NULL,
                created_at REAL NOT NULL,
                event_seq INTEGER NOT NULL,
                FOREIGN KEY(session_id) REFERENCES sessions(session_id) ON DELETE SET NULL
            );

            CREATE TABLE IF NOT EXISTS settings_snapshots (
                id TEXT PRIMARY KEY,
                created_at REAL NOT NULL,
                payload_json TEXT NOT NULL
            );

            CREATE TABLE IF NOT EXISTS session_metrics (
                id TEXT PRIMARY KEY,
                session_id TEXT,
                metric_name TEXT NOT NULL,
                metric_value REAL NOT NULL,
                created_at REAL NOT NULL,
                FOREIGN KEY(session_id) REFERENCES sessions(session_id) ON DELETE SET NULL
            );

            CREATE TABLE IF NOT EXISTS metrics_rollup_1m (
                id TEXT PRIMARY KEY,
                bucket_start REAL NOT NULL,
                metric_name TEXT NOT NULL,
                metric_value REAL NOT NULL
            );
            """,
            on: db
        )
    }

    private static func executeSQL(_ sql: String, on db: OpaquePointer) throws {
        var errorMessage: UnsafeMutablePointer<Int8>?
        let status = sqlite3_exec(db, sql, nil, nil, &errorMessage)
        guard status == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? "Unknown SQL error"
            sqlite3_free(errorMessage)
            throw HistoryStoreError.sqlError(message: message)
        }
    }

    private func execute(_ sql: String) throws {
        guard let db else {
            throw HistoryStoreError.databaseOpenFailed
        }

        var errorMessage: UnsafeMutablePointer<Int8>?
        let status = sqlite3_exec(db, sql, nil, nil, &errorMessage)
        guard status == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? "Unknown SQL error"
            sqlite3_free(errorMessage)
            throw HistoryStoreError.sqlError(message: message)
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        guard let db else {
            throw HistoryStoreError.databaseOpenFailed
        }
        var statement: OpaquePointer?
        let status = sqlite3_prepare_v2(db, sql, -1, &statement, nil)
        guard status == SQLITE_OK, let statement else {
            throw HistoryStoreError.sqlError(message: lastSQLError())
        }
        return statement
    }

    private func stepDone(_ statement: OpaquePointer) throws {
        let status = sqlite3_step(statement)
        guard status == SQLITE_DONE else {
            throw HistoryStoreError.sqlError(message: lastSQLError())
        }
        sqlite3_reset(statement)
    }

    private func bindText(_ value: String, to index: Int32, in statement: OpaquePointer) {
        sqlite3_bind_text(statement, index, (value as NSString).utf8String, -1, SQLITE_TRANSIENT)
    }

    private func bindOptionalText(_ value: String?, to index: Int32, in statement: OpaquePointer) {
        if let value {
            sqlite3_bind_text(statement, index, (value as NSString).utf8String, -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(statement, index)
        }
    }

    private func bindInt32(_ value: Int32, to index: Int32, in statement: OpaquePointer) {
        sqlite3_bind_int(statement, index, value)
    }

    private func bindInt64(_ value: Int64, to index: Int32, in statement: OpaquePointer) {
        sqlite3_bind_int64(statement, index, value)
    }

    private func bindDouble(_ value: Double, to index: Int32, in statement: OpaquePointer) {
        sqlite3_bind_double(statement, index, value)
    }

    private func lastSQLError() -> String {
        guard let db, let cString = sqlite3_errmsg(db) else {
            return "Unknown SQL error"
        }
        return String(cString: cString)
    }

    private func nextEventSequence(sessionID: UUID?) -> Int64 {
        guard let sessionID else {
            return Int64(Date().timeIntervalSince1970 * 1000)
        }

        do {
            let statement = try prepare(
                """
                SELECT COALESCE(MAX(event_seq), 0) + 1
                FROM session_events
                WHERE session_id = ?;
                """
            )
            defer { sqlite3_finalize(statement) }
            bindText(sessionID.uuidString, to: 1, in: statement)
            if sqlite3_step(statement) == SQLITE_ROW {
                return sqlite3_column_int64(statement, 0)
            }
        } catch {
            return Int64(Date().timeIntervalSince1970 * 1000)
        }

        return Int64(Date().timeIntervalSince1970 * 1000)
    }

    private func legacyHistorySource() -> URL {
        let environment = ProcessInfo.processInfo.environment
        let legacyPath: URL
        let currentPath: URL
        if let xdgData = environment["XDG_DATA_HOME"], !xdgData.isEmpty {
            legacyPath = URL(fileURLWithPath: xdgData)
                .appendingPathComponent("whisper-assistant/history", isDirectory: true)
            currentPath = URL(fileURLWithPath: xdgData)
                .appendingPathComponent("quedo/history", isDirectory: true)
        } else {
            let home = fileManager.homeDirectoryForCurrentUser
            legacyPath = home
                .appendingPathComponent(".local/share/whisper-assistant/history", isDirectory: true)
            currentPath = home
                .appendingPathComponent(".local/share/quedo/history", isDirectory: true)
        }
        if fileManager.fileExists(atPath: legacyPath.path) {
            return legacyPath
        }
        return currentPath
    }

    private func deterministicSessionID(forLegacyPath path: String) -> UUID {
        let digest = SHA256.hash(data: Data(path.utf8))
        let bytes = Array(digest.prefix(16))

        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    private func parseLegacyDate(date: String, time: String) -> Date {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd HHmmss"

        let combined = "\(date) \(time)"
        return formatter.date(from: combined) ?? Date()
    }

    private func persistAudioArtifact(sessionID: UUID, sourcePath: URL) throws -> URL {
        let extensionComponent = sourcePath.pathExtension.isEmpty ? "caf" : sourcePath.pathExtension
        let destinationDirectory = baseURL
            .appendingPathComponent("media", isDirectory: true)
            .appendingPathComponent(sessionID.uuidString, isDirectory: true)
        let destination = destinationDirectory.appendingPathComponent("recording.\(extensionComponent)")

        if sourcePath.standardizedFileURL == destination.standardizedFileURL {
            return destination
        }

        try fileManager.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.copyItem(at: sourcePath, to: destination)
        if shouldDeleteTemporarySourceAfterCopy(sourcePath: sourcePath, destinationPath: destination) {
            try? fileManager.removeItem(at: sourcePath)
        }

        return destination
    }

    private func shouldDeleteTemporarySourceAfterCopy(sourcePath: URL, destinationPath: URL) -> Bool {
        let source = sourcePath.standardizedFileURL.path
        let destination = destinationPath.standardizedFileURL.path
        guard source != destination else {
            return false
        }

        let tempRoot = URL(fileURLWithPath: NSTemporaryDirectory()).standardizedFileURL.path
        return source.hasPrefix(tempRoot)
    }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
