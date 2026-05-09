import ArgumentParser
import Foundation
import QuedoCore

private struct ProcessRunResult {
    let status: Int32
    let stderr: String
}

private func runProcess(_ executablePath: String, arguments: [String]) throws -> ProcessRunResult {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executablePath)
    process.arguments = arguments

    let stderrPipe = Pipe()
    process.standardError = stderrPipe

    try process.run()
    process.waitUntilExit()

    let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
    let stderr = String(data: stderrData, encoding: .utf8) ?? ""
    return ProcessRunResult(status: process.terminationStatus, stderr: stderr)
}

private func installedQuedoAppURL() -> URL? {
    let fileManager = FileManager.default
    let candidates: [URL] = [
        URL(fileURLWithPath: "/Applications/Quedo.app"),
        fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications", isDirectory: true)
            .appendingPathComponent("Quedo.app", isDirectory: true)
    ]

    return candidates.first { fileManager.fileExists(atPath: $0.path) }
}

private func localQuedoBinaryURL() -> URL? {
    let currentExecutable = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    let sibling = currentExecutable.deletingLastPathComponent().appendingPathComponent("Quedo")
    return FileManager.default.isExecutableFile(atPath: sibling.path) ? sibling : nil
}

@main
struct QuedoCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "quedo-cli",
        abstract: "Quedo companion CLI",
        subcommands: [
            Start.self,
            Stop.self,
            Status.self,
            Logs.self,
            Doctor.self,
            Config.self,
            History.self,
            Transcribe.self
        ]
    )
}

struct Start: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Launch Quedo app")

    mutating func run() async throws {
        if let appURL = installedQuedoAppURL() {
            let result = try runProcess("/usr/bin/open", arguments: [appURL.path])
            if result.status == 0 {
                print("start requested (\(appURL.path))")
                return
            }
        }

        if let localBinary = localQuedoBinaryURL() {
            let localProcess = Process()
            localProcess.executableURL = localBinary
            try localProcess.run()
            print("start requested (local binary)")
            return
        }

        let result = try runProcess("/usr/bin/open", arguments: ["-a", "Quedo"])
        if result.status == 0 {
            print("start requested")
            return
        }

        let errorOutput = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if !errorOutput.isEmpty {
            throw ValidationError(errorOutput)
        }
        throw ValidationError("open failed with status \(result.status)")
    }
}

struct Stop: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Stop Quedo app")

    mutating func run() async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        process.arguments = ["-x", "Quedo"]
        try process.run()
        process.waitUntilExit()
        switch process.terminationStatus {
        case 0:
            print("stop requested")
        case 1:
            print("no running Quedo process found")
        default:
            throw ValidationError("pkill failed with status \(process.terminationStatus)")
        }
    }
}

struct Status: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Show runtime readiness status")

    mutating func run() async throws {
        let permissions = await PermissionCoordinator().checkAll()
        let settings = try await ConfigurationManager().redactedSnapshot()

        print("microphone=\(permissions.microphone.rawValue)")
        print("accessibility=\(permissions.accessibility.rawValue)")
        print("input_monitoring=\(permissions.inputMonitoring.rawValue)")
        print("settings=\(settings)")
    }
}

struct Logs: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Show active logs")

    @Flag(help: "Show debug.log when available")
    var debug = false

    @Flag(help: "Show hotkeys.log with key registration/dispatch trace")
    var hotkeys = false

    mutating func run() async throws {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Quedo/logs")
        let file: URL
        if hotkeys {
            file = base.appendingPathComponent("hotkeys.log")
        } else if debug {
            file = base.appendingPathComponent("debug.log")
        } else {
            file = base.appendingPathComponent("app.log")
        }

        if !FileManager.default.fileExists(atPath: file.path) {
            print("log file not found: \(file.path)")
            return
        }

        let content = try String(contentsOf: file, encoding: .utf8)
        print(content)
    }
}

struct Doctor: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Run diagnostics checks")

    mutating func run() async throws {
        let config = ConfigurationManager()
        let settings = try await config.loadSettings()

        let permissions = await PermissionCoordinator().checkAll()
        print("permissions.microphone=\(permissions.microphone.rawValue)")
        print("permissions.accessibility=\(permissions.accessibility.rawValue)")
        print("permissions.inputMonitoring=\(permissions.inputMonitoring.rawValue)")

        let groq = GroqProvider(timeoutSeconds: settings.provider.timeoutSeconds) {
            try await config.loadAPIKey(for: .groq) ?? ""
        }
        let openAI = OpenAIProvider(timeoutSeconds: settings.provider.timeoutSeconds) {
            try await config.loadAPIKey(for: .openAI) ?? ""
        }
        let elevenLabs = ElevenLabsProvider(timeoutSeconds: settings.provider.timeoutSeconds) {
            try await config.loadAPIKey(for: .elevenLabs) ?? ""
        }
        let whisperCpp = WhisperCppProvider(timeoutSeconds: settings.provider.timeoutSeconds) {
            try await config.loadSettings().provider.whisperCppModelPath
        } runtimeProvider: {
            try await config.loadSettings().provider.whisperCppRuntime
        }

        let pipeline = TranscriptionPipeline(
            providers: [groq, openAI, elevenLabs, whisperCpp],
            requestTimeoutSeconds: settings.provider.timeoutSeconds
        )
        let check = await pipeline.connectivityCheck(primary: settings.provider.primary, fallback: settings.provider.fallback)
        print("provider.primary.ok=\(check.primaryOK)")
        print("provider.fallback.ok=\(check.fallbackOK)")
    }
}

struct Config: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Configuration commands",
        subcommands: [Show.self]
    )

    struct Show: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Print non-secret settings")

        mutating func run() async throws {
            let snapshot = try await ConfigurationManager().redactedSnapshot()
            for key in snapshot.keys.sorted() {
                if let value = snapshot[key] {
                    print("\(key)=\(value)")
                }
            }
        }
    }
}

struct History: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "History commands",
        subcommands: [List.self, Play.self, TranscribeFromHistory.self]
    )

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List recent sessions")

        @Option(help: "Maximum number of sessions")
        var limit: Int = 20

        mutating func run() async throws {
            let store = try HistoryStore()
            let sessions = try await store.listSessions(limit: limit)
            for (index, session) in sessions.enumerated() {
                print("\(index + 1). \(session.createdAt) \(session.providerUsed.rawValue) \(session.status.rawValue) \(session.transcriptPreview)")
            }
        }
    }

    struct Play: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Play session audio by latest index")

        @Argument(help: "Session index from `history list` output")
        var index: Int

        mutating func run() async throws {
            let store = try HistoryStore()
            let sessions = try await store.listSessions(limit: max(index, 50))
            guard index > 0, index <= sessions.count else {
                throw ValidationError("Invalid history index")
            }

            let target = sessions[index - 1]
            guard let source = try await store.primaryAudioFileURL(sessionID: target.sessionID) else {
                throw ValidationError("No media path recorded for selected session")
            }
            guard FileManager.default.fileExists(atPath: source.path) else {
                throw ValidationError("Recorded media path does not exist: \(source.path)")
            }

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
            process.arguments = [source.path]
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw ValidationError("afplay failed with status \(process.terminationStatus)")
            }
        }
    }

    struct TranscribeFromHistory: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "transcribe", abstract: "Re-transcribe a history item")

        @Argument(help: "Session index from `history list` output")
        var index: Int

        @Option(help: "Language override")
        var language: String?

        mutating func run() async throws {
            let store = try HistoryStore()
            let sessions = try await store.listSessions(limit: max(index, 50))
            guard index > 0, index <= sessions.count else {
                throw ValidationError("Invalid history index")
            }

            let target = sessions[index - 1]
            guard let source = try await store.primaryAudioFileURL(sessionID: target.sessionID) else {
                throw ValidationError("No media path recorded for selected session")
            }
            guard FileManager.default.fileExists(atPath: source.path) else {
                throw ValidationError("Recorded media path does not exist: \(source.path)")
            }

            var command = Transcribe()
            command.file = source.path
            command.language = language
            try await command.run()
        }
    }
}

struct Transcribe: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Transcribe an audio file")

    @Argument(help: "Path to local audio file")
    var file: String

    @Option(help: "Language override")
    var language: String?

    mutating func run() async throws {
        let source = URL(fileURLWithPath: file)
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw ValidationError("File does not exist: \(source.path)")
        }

        let config = ConfigurationManager()
        var settings = try await config.loadSettings()
        if let language, !language.isEmpty {
            settings.language = language
        }

        let groq = GroqProvider(timeoutSeconds: settings.provider.timeoutSeconds) {
            try await config.loadAPIKey(for: .groq) ?? ""
        }
        let openAI = OpenAIProvider(timeoutSeconds: settings.provider.timeoutSeconds) {
            try await config.loadAPIKey(for: .openAI) ?? ""
        }
        let elevenLabs = ElevenLabsProvider(timeoutSeconds: settings.provider.timeoutSeconds) {
            try await config.loadAPIKey(for: .elevenLabs) ?? ""
        }
        let whisperCpp = WhisperCppProvider(timeoutSeconds: settings.provider.timeoutSeconds) {
            try await config.loadSettings().provider.whisperCppModelPath
        } runtimeProvider: {
            try await config.loadSettings().provider.whisperCppRuntime
        }

        let pipeline = TranscriptionPipeline(
            providers: [groq, openAI, elevenLabs, whisperCpp],
            requestTimeoutSeconds: settings.provider.timeoutSeconds
        )
        let result = try await pipeline.transcribe(audioFileURL: source, settings: settings)
        print(result.text)
    }
}
