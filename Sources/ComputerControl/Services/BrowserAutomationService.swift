import Foundation

struct BrowserAutomationRequest: Codable {
    var text: String
    var url: String?
    var maxSteps: Int?
    var browserBackend: String?
    var browserProfileMode: String?
    var browserProfile: String?
}

struct BrowserAutomationResult: Decodable {
    var ok: Bool
    var spokenText: String
    var detail: String
    var steps: [String]
    var finalURL: String?
    var screenshotPath: String?
    var contextKind: String?
    var contextTitle: String?
    var contextSource: String?
}

@MainActor
final class BrowserAutomationService {
    private var currentProcess: Process?

    func run(goal: String, url: String?, maxSteps: Int?, browserBackend: String?, browserProfileMode: String?, browserProfile: String?) async throws -> BrowserAutomationResult {
        let runnerURL = try locateRunner()
        let projectRoot = runnerURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let payload = try JSONEncoder().encode(
            BrowserAutomationRequest(
                text: goal,
                url: url,
                maxSteps: maxSteps,
                browserBackend: browserBackend,
                browserProfileMode: browserProfileMode,
                browserProfile: browserProfile
            )
        )

        return try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            currentProcess = process
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["node", runnerURL.path]
            process.currentDirectoryURL = projectRoot

            var environment = ProcessInfo.processInfo.environment
            if let key = OpenAIConfiguration.apiKey() {
                environment["OPENAI_API_KEY"] = key
            }
            environment["BROWSER_USER_DATA_DIR"] = browserUserDataDirectory().path
            process.environment = environment

            let inputPipe = Pipe()
            let outputPipe = Pipe()
            let errorPipe = Pipe()
            process.standardInput = inputPipe
            process.standardOutput = outputPipe
            process.standardError = errorPipe

            process.terminationHandler = { [weak self] process in
                let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
                let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()

                Task { @MainActor in
                    if self?.currentProcess === process {
                        self?.currentProcess = nil
                    }
                }

                if process.terminationStatus != 0 {
                    let stderr = String(data: errorData, encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    continuation.resume(throwing: BrowserAutomationError.failed(stderr ?? "Browser runner exited with \(process.terminationStatus)."))
                    return
                }

                do {
                    let resultData = try Self.extractLastJSONLine(from: outputData)
                    let result = try JSONDecoder().decode(BrowserAutomationResult.self, from: resultData)
                    continuation.resume(returning: result)
                } catch {
                    let stdout = String(data: outputData, encoding: .utf8) ?? ""
                    let stderr = String(data: errorData, encoding: .utf8) ?? ""
                    continuation.resume(
                        throwing: BrowserAutomationError.failed(
                            "Could not parse browser runner output. stdout=\(stdout.prefix(800)) stderr=\(stderr.prefix(800))"
                        )
                    )
                }
            }

            do {
                try process.run()
                inputPipe.fileHandleForWriting.write(payload)
                inputPipe.fileHandleForWriting.closeFile()
            } catch {
                currentProcess = nil
                continuation.resume(throwing: error)
            }
        }
    }

    func cancelCurrentTask() {
        currentProcess?.terminate()
    }

    private func locateRunner() throws -> URL {
        let fileManager = FileManager.default
        for root in AppPaths.projectRootCandidates() {
            let runner = root
                .appendingPathComponent("script", isDirectory: true)
                .appendingPathComponent("browser-agent.mjs")
            if fileManager.fileExists(atPath: runner.path) {
                return runner
            }
        }

        throw BrowserAutomationError.failed("Could not find script/browser-agent.mjs.")
    }

    private func browserUserDataDirectory() -> URL {
        AppPaths.managedBrowserProfileDirectory()
    }

    nonisolated static func extractLastJSONLine(from data: Data) throws -> Data {
        guard let output = String(data: data, encoding: .utf8) else {
            throw BrowserAutomationError.failed("Browser runner returned non-UTF8 output.")
        }

        guard let line = output
            .split(whereSeparator: \.isNewline)
            .last(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{") }) else {
            throw BrowserAutomationError.failed("Browser runner did not return JSON.")
        }

        return Data(String(line).utf8)
    }
}

enum BrowserAutomationError: LocalizedError {
    case failed(String)

    var errorDescription: String? {
        switch self {
        case let .failed(message):
            message
        }
    }
}
