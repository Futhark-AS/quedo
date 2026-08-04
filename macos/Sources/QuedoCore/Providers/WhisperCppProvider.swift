import Foundation

/// Local whisper.cpp transcription provider implementation.
public struct WhisperCppProvider: TranscriptionProvider {
    /// Provider family identifier.
    public let kind: ProviderKind = .whisperCpp

    /// whisper.cpp accepts local audio formats directly; FLAC upload conversion is unnecessary.
    public var requiresFLACUpload: Bool { false }

    private let timeoutSeconds: Int
    private let cliExecutablePath: String
    private let serverExecutablePath: String
    private let modelPathProvider: @Sendable () async throws -> String
    private let runtimeProvider: @Sendable () async throws -> WhisperCppRuntime
    private let serverManager: WhisperCppServerManager

    /// Creates a whisper.cpp provider.
    public init(
        timeoutSeconds: Int,
        executablePath: String = "whisper-cli",
        serverExecutablePath: String = "whisper-server",
        modelPathProvider: @escaping @Sendable () async throws -> String = {
            ProviderConfiguration.defaultValue.whisperCppModelPath
        },
        runtimeProvider: @escaping @Sendable () async throws -> WhisperCppRuntime = {
            ProviderConfiguration.defaultValue.whisperCppRuntime
        }
    ) {
        self.timeoutSeconds = timeoutSeconds
        self.cliExecutablePath = executablePath
        self.serverExecutablePath = serverExecutablePath
        self.modelPathProvider = modelPathProvider
        self.runtimeProvider = runtimeProvider
        self.serverManager = WhisperCppServerManager()
    }

    /// Transcribes audio using runtime-selected whisper.cpp backend.
    public func transcribe(request: TranscriptionRequest) async throws -> TranscriptionResponse {
        guard let modelURL = resolveModelURL(from: request.model) else {
            throw ProviderError.terminal(
                statusCode: 2,
                message: "whisper.cpp model not found: \(request.model)"
            )
        }

        let runtime = try await runtimeProvider()
        return try await transcribe(request: request, modelURL: modelURL, runtime: runtime)
    }

    /// Stops any managed whisper-server process.
    public func shutdownServer() async {
        await serverManager.shutdown()
    }

    /// Checks if configured whisper.cpp runtime is reachable.
    public func checkHealth(timeoutSeconds: Int) async -> Bool {
        let timeout = max(1, timeoutSeconds)

        let modelPath: String
        do {
            modelPath = try await modelPathProvider()
        } catch {
            return false
        }

        guard let modelURL = resolveModelURL(from: modelPath) else {
            return false
        }

        let runtime = (try? await runtimeProvider()) ?? .auto

        switch runtime {
        case .cli:
            return resolveExecutableURL(for: cliExecutablePath) != nil
        case .server:
            guard let serverExecutableURL = resolveExecutableURL(for: serverExecutablePath) else {
                return false
            }
            return (try? await serverManager.ensureServer(
                executableURL: serverExecutableURL,
                modelURL: modelURL,
                timeoutSeconds: timeout
            )) != nil
        case .auto:
            if let serverExecutableURL = resolveExecutableURL(for: serverExecutablePath),
               (try? await serverManager.ensureServer(
                    executableURL: serverExecutableURL,
                    modelURL: modelURL,
                    timeoutSeconds: timeout
               )) != nil {
                return true
            }
            return resolveExecutableURL(for: cliExecutablePath) != nil
        }
    }

    private func transcribe(
        request: TranscriptionRequest,
        modelURL: URL,
        runtime: WhisperCppRuntime
    ) async throws -> TranscriptionResponse {
        let serverExecutableURL = resolveExecutableURL(for: serverExecutablePath)
        let cliExecutableURL = resolveExecutableURL(for: cliExecutablePath)

        switch runtime {
        case .server:
            guard let serverExecutableURL else {
                throw ProviderError.terminal(statusCode: 127, message: "\(serverExecutablePath) not found in PATH")
            }
            return try await transcribeWithServer(
                request: request,
                modelURL: modelURL,
                serverExecutableURL: serverExecutableURL
            )
        case .cli:
            guard let cliExecutableURL else {
                throw ProviderError.terminal(statusCode: 127, message: "\(cliExecutablePath) not found in PATH")
            }
            return try await transcribeWithCLI(
                request: request,
                modelURL: modelURL,
                executableURL: cliExecutableURL
            )
        case .auto:
            if let serverExecutableURL {
                do {
                    return try await transcribeWithServer(
                        request: request,
                        modelURL: modelURL,
                        serverExecutableURL: serverExecutableURL
                    )
                } catch {
                    if let cliExecutableURL {
                        return try await transcribeWithCLI(
                            request: request,
                            modelURL: modelURL,
                            executableURL: cliExecutableURL
                        )
                    }
                    throw error
                }
            }

            guard let cliExecutableURL else {
                throw ProviderError.terminal(
                    statusCode: 127,
                    message: "Neither \(serverExecutablePath) nor \(cliExecutablePath) found in PATH"
                )
            }
            return try await transcribeWithCLI(
                request: request,
                modelURL: modelURL,
                executableURL: cliExecutableURL
            )
        }
    }

    private func transcribeWithCLI(
        request: TranscriptionRequest,
        modelURL: URL,
        executableURL: URL
    ) async throws -> TranscriptionResponse {
        let fileManager = FileManager.default
        let outputDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("QuedoWhisperCpp", isDirectory: true)
        try fileManager.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let outputPrefix = outputDirectory.appendingPathComponent(UUID().uuidString)
        let outputTextFile = outputPrefix.appendingPathExtension("txt")
        defer {
            try? fileManager.removeItem(at: outputTextFile)
        }

        var arguments: [String] = [
            "-m", modelURL.path,
            "-f", request.audioFileURL.path,
            "-l", request.language,
            "-otxt",
            "-nt",
            "-np",
            "-of", outputPrefix.path
        ]

        let context = request.context?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let prompt = buildPrompt(context: context, vocabularyHints: request.vocabularyHints)
        if !prompt.isEmpty {
            arguments.append(contentsOf: ["--prompt", prompt])
        }

        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.currentDirectoryURL = outputDirectory

        var environment = ProcessInfo.processInfo.environment
        environment["NO_COLOR"] = "1"
        process.environment = environment

        let stderrPipe = Pipe()
        process.standardOutput = Pipe()
        process.standardError = stderrPipe

        do {
            try process.run()
            let deadline = Date().addingTimeInterval(TimeInterval(max(1, timeoutSeconds)))
            while process.isRunning {
                try Task.checkCancellation()
                if Date() >= deadline {
                    process.terminate()
                    throw ProviderError.timeout
                }
                try await Task.sleep(for: .milliseconds(50))
            }
        } catch is CancellationError {
            if process.isRunning {
                process.terminate()
            }
            throw CancellationError()
        } catch let providerError as ProviderError {
            if process.isRunning {
                process.terminate()
            }
            throw providerError
        } catch {
            if process.isRunning {
                process.terminate()
            }
            throw ProviderError.networkFailure
        }

        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        let stderr = String(data: stderrData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if process.terminationStatus != 0 {
            throw ProviderError.terminal(
                statusCode: Int(process.terminationStatus),
                message: stderr.isEmpty ? "\(cliExecutablePath) failed" : stderr
            )
        }

        guard fileManager.fileExists(atPath: outputTextFile.path) else {
            throw ProviderError.invalidResponse
        }

        let rawText = try String(contentsOf: outputTextFile, encoding: .utf8)
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        return TranscriptionResponse(text: text, provider: .whisperCpp, isPartial: false)
    }

    private func transcribeWithServer(
        request: TranscriptionRequest,
        modelURL: URL,
        serverExecutableURL: URL
    ) async throws -> TranscriptionResponse {
        let inferenceURL = try await serverManager.ensureServer(
            executableURL: serverExecutableURL,
            modelURL: modelURL,
            timeoutSeconds: timeoutSeconds
        )

        let boundary = "QuedoBoundary-\(UUID().uuidString)"
        let prompt = buildPrompt(
            context: request.context?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            vocabularyHints: request.vocabularyHints
        )
        let body = try buildMultipartBody(
            audioFileURL: request.audioFileURL,
            language: request.language,
            prompt: prompt,
            boundary: boundary
        )

        var urlRequest = URLRequest(url: inferenceURL)
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = TimeInterval(max(1, timeoutSeconds))
        urlRequest.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.upload(for: urlRequest, from: body)
        } catch {
            throw ProviderError.networkFailure
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ProviderError.networkFailure
        }

        let statusCode = httpResponse.statusCode
        if (200..<300).contains(statusCode) {
            if let payload = try? JSONDecoder().decode(WhisperServerTextResponse.self, from: data) {
                return TranscriptionResponse(
                    text: payload.text.trimmingCharacters(in: .whitespacesAndNewlines),
                    provider: .whisperCpp,
                    isPartial: false
                )
            }

            if let plain = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !plain.isEmpty {
                return TranscriptionResponse(text: plain, provider: .whisperCpp, isPartial: false)
            }

            throw ProviderError.invalidResponse
        }

        let message = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if (500..<600).contains(statusCode) {
            throw ProviderError.transient(statusCode: statusCode)
        }

        throw ProviderError.terminal(
            statusCode: statusCode,
            message: message.isEmpty ? "\(serverExecutablePath) inference failed" : message
        )
    }

    private func buildPrompt(context: String, vocabularyHints: [String]) -> String {
        var parts: [String] = []
        if !context.isEmpty {
            parts.append(context)
        }
        if !vocabularyHints.isEmpty {
            parts.append(vocabularyHints.joined(separator: ", "))
        }
        return parts.joined(separator: "\n")
    }

    private func resolveExecutableURL(for configuredPath: String) -> URL? {
        let fileManager = FileManager.default
        let expanded = (configuredPath as NSString).expandingTildeInPath
        if expanded.contains("/") {
            return fileManager.isExecutableFile(atPath: expanded) ? URL(fileURLWithPath: expanded) : nil
        }

        let pathValue = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let pathSegments = pathValue
            .split(separator: ":")
            .map(String.init)
            .filter { !$0.isEmpty }
        for segment in pathSegments {
            let candidate = URL(fileURLWithPath: segment, isDirectory: true)
                .appendingPathComponent(expanded)
            if fileManager.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }

        let fallbackPaths = [
            "/opt/homebrew/bin/\(expanded)",
            "/usr/local/bin/\(expanded)"
        ]
        for fallback in fallbackPaths where fileManager.isExecutableFile(atPath: fallback) {
            return URL(fileURLWithPath: fallback)
        }
        return nil
    }

    private func resolveModelURL(from rawModel: String) -> URL? {
        let fileManager = FileManager.default
        let trimmed = rawModel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }

        let expanded = (trimmed as NSString).expandingTildeInPath
        let directPath: String
        if expanded.hasPrefix("/") {
            directPath = expanded
        } else {
            directPath = URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true)
                .appendingPathComponent(expanded)
                .path
        }

        if fileManager.fileExists(atPath: directPath) {
            return URL(fileURLWithPath: directPath)
        }

        guard !expanded.contains("/") else {
            return nil
        }

        let candidateDirectories: [URL] = [
            URL(fileURLWithPath: "/opt/homebrew/opt/whisper-cpp/share/whisper/models", isDirectory: true),
            URL(fileURLWithPath: "/usr/local/opt/whisper-cpp/share/whisper/models", isDirectory: true),
            URL(fileURLWithPath: "/opt/homebrew/share/whisper/models", isDirectory: true),
            URL(fileURLWithPath: "/usr/local/share/whisper/models", isDirectory: true),
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".cache/whisper", isDirectory: true)
        ]

        for directory in candidateDirectories {
            let candidate = directory.appendingPathComponent(expanded)
            if fileManager.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    private func buildMultipartBody(
        audioFileURL: URL,
        language: String,
        prompt: String,
        boundary: String
    ) throws -> Data {
        var body = Data()

        appendMultipartField(name: "response_format", value: "json", boundary: boundary, to: &body)

        let trimmedLanguage = language.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedLanguage.isEmpty, trimmedLanguage.lowercased() != "auto" {
            appendMultipartField(name: "language", value: trimmedLanguage, boundary: boundary, to: &body)
        }

        if !prompt.isEmpty {
            appendMultipartField(name: "prompt", value: prompt, boundary: boundary, to: &body)
        }

        let fileData = try Data(contentsOf: audioFileURL)
        body.appendUTF8("--\(boundary)\r\n")
        body.appendUTF8("Content-Disposition: form-data; name=\"file\"; filename=\"\(audioFileURL.lastPathComponent)\"\r\n")
        body.appendUTF8("Content-Type: application/octet-stream\r\n\r\n")
        body.append(fileData)
        body.appendUTF8("\r\n")
        body.appendUTF8("--\(boundary)--\r\n")

        return body
    }

    private func appendMultipartField(name: String, value: String, boundary: String, to body: inout Data) {
        body.appendUTF8("--\(boundary)\r\n")
        body.appendUTF8("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
        body.appendUTF8(value)
        body.appendUTF8("\r\n")
    }
}

private actor WhisperCppServerManager {
    private var process: Process?
    private var baseURL: URL?
    private var modelPath: String?
    private var executablePath: String?

    func ensureServer(
        executableURL: URL,
        modelURL: URL,
        timeoutSeconds: Int
    ) async throws -> URL {
        if let process,
           process.isRunning,
           let baseURL,
           modelPath == modelURL.path,
           executablePath == executableURL.path,
           await isHealthy(baseURL: baseURL, timeoutSeconds: 1) {
            return baseURL.appendingPathComponent("inference")
        }

        stopServer()
        await killOrphanedServers()

        for port in candidatePorts() {
            let baseURL = URL(string: "http://127.0.0.1:\(port)")!
            let process = Process()
            process.executableURL = executableURL
            process.arguments = [
                "-m", modelURL.path,
                "--host", "127.0.0.1",
                "--port", String(port)
            ]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice

            do {
                try process.run()
            } catch {
                continue
            }

            if await waitForHealth(baseURL: baseURL, process: process, timeoutSeconds: timeoutSeconds) {
                self.process = process
                self.baseURL = baseURL
                self.modelPath = modelURL.path
                self.executablePath = executableURL.path
                return baseURL.appendingPathComponent("inference")
            }

            if process.isRunning {
                process.terminate()
            }
        }

        throw ProviderError.networkFailure
    }

    func shutdown() {
        stopServer()
    }

    private func killOrphanedServers() async {
        let killProcess = Process()
        killProcess.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        killProcess.arguments = ["-x", "whisper-server"]
        killProcess.standardOutput = FileHandle.nullDevice
        killProcess.standardError = FileHandle.nullDevice
        try? killProcess.run()
        // Give processes time to exit and release ports.
        try? await Task.sleep(for: .milliseconds(200))
    }

    private func stopServer() {
        if let process, process.isRunning {
            process.terminate()
        }
        process = nil
        baseURL = nil
        modelPath = nil
        executablePath = nil
    }

    private func waitForHealth(baseURL: URL, process: Process, timeoutSeconds: Int) async -> Bool {
        let timeout = max(1, timeoutSeconds)
        let deadline = Date().addingTimeInterval(TimeInterval(timeout))

        while Date() < deadline {
            if !process.isRunning {
                return false
            }

            if await isHealthy(baseURL: baseURL, timeoutSeconds: 1) {
                return true
            }

            try? await Task.sleep(for: .milliseconds(120))
        }

        return false
    }

    private func isHealthy(baseURL: URL, timeoutSeconds: Int) async -> Bool {
        guard let url = URL(string: "health", relativeTo: baseURL) else {
            return false
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = TimeInterval(max(1, timeoutSeconds))

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, (200..<300).contains(httpResponse.statusCode) else {
                return false
            }

            guard let payload = String(data: data, encoding: .utf8)?.lowercased() else {
                return true
            }
            return payload.contains("ok")
        } catch {
            return false
        }
    }

    private func candidatePorts() -> [Int] {
        var ports = [18080, 18081, 18082]
        for _ in 0..<8 {
            ports.append(Int.random(in: 20_000...45_000))
        }
        return ports
    }
}

private struct WhisperServerTextResponse: Decodable {
    let text: String
}

private extension Data {
    mutating func appendUTF8(_ string: String) {
        append(contentsOf: string.utf8)
    }
}
