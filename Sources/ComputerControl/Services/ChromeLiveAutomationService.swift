import Foundation
import Observation

@Observable
@MainActor
final class ChromeLiveAutomationService {
    var status: ChromeLiveStatus = .unknown
    var statusDetail = "Not checked yet."

    private var currentProcess: Process?
    private let bridgePort = 38433

    var statusTitle: String {
        switch status {
        case .connected: "Live Chrome"
        case .missing: "Chrome setup"
        case .checking: "Checking Chrome"
        case .running: "Chrome task"
        case .unknown: "Chrome ?"
        }
    }

    var isConnected: Bool {
        status == .connected
    }

    func refreshStatus() async {
        status = .checking
        do {
            let result = try await runBridge(arguments: ["--status"], payload: nil, timeout: 4)
            if result.ok {
                status = .connected
                statusDetail = result.detail
            } else {
                status = .missing
                statusDetail = result.detail
            }
        } catch {
            status = .missing
            statusDetail = error.localizedDescription
        }
    }

    func run(goal: String, url: String?, maxSteps: Int?) async throws -> BrowserAutomationResult {
        let request = BrowserAutomationRequest(
            text: goal,
            url: url,
            maxSteps: maxSteps,
            browserBackend: "live_chrome",
            browserProfileMode: nil,
            browserProfile: nil
        )
        let payload = try JSONEncoder().encode(request)

        status = .running
        defer {
            if status == .running {
                status = .unknown
            }
        }

        let result = try await runBridge(arguments: [], payload: payload, timeout: 180)
        status = result.detail.localizedCaseInsensitiveContains("companion extension") ? .missing : .connected
        statusDetail = result.detail
        return result
    }

    func cancelCurrentTask() {
        currentProcess?.terminate()
        status = .unknown
        statusDetail = "Cancelled current live Chrome task."
    }

    private func runBridge(arguments: [String], payload: Data?, timeout: TimeInterval) async throws -> BrowserAutomationResult {
        let runnerURL = try locateRunner(named: "chrome-live-agent.mjs")
        let projectRoot = runnerURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        return try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            currentProcess = process
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["node", runnerURL.path] + arguments
            process.currentDirectoryURL = projectRoot

            var environment = ProcessInfo.processInfo.environment
            if let key = OpenAIConfiguration.apiKey() {
                environment["OPENAI_API_KEY"] = key
            }
            environment["CHROME_LIVE_BRIDGE_PORT"] = "\(bridgePort)"
            process.environment = environment

            let inputPipe = Pipe()
            let outputPipe = Pipe()
            let errorPipe = Pipe()
            process.standardInput = inputPipe
            process.standardOutput = outputPipe
            process.standardError = errorPipe

            let processBox = ProcessHandleBox(process)
            let timeoutTask = Task.detached {
                try? await Task.sleep(for: .seconds(timeout))
                if !Task.isCancelled, processBox.process.isRunning {
                    processBox.process.terminate()
                }
            }

            process.terminationHandler = { [weak self] process in
                timeoutTask.cancel()

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
                    continuation.resume(throwing: BrowserAutomationError.failed(stderr ?? "Live Chrome runner exited with \(process.terminationStatus)."))
                    return
                }

                do {
                    let resultData = try BrowserAutomationService.extractLastJSONLine(from: outputData)
                    let result = try JSONDecoder().decode(BrowserAutomationResult.self, from: resultData)
                    continuation.resume(returning: result)
                } catch {
                    let stdout = String(data: outputData, encoding: .utf8) ?? ""
                    let stderr = String(data: errorData, encoding: .utf8) ?? ""
                    continuation.resume(
                        throwing: BrowserAutomationError.failed(
                            "Could not parse live Chrome runner output. stdout=\(stdout.prefix(800)) stderr=\(stderr.prefix(800))"
                        )
                    )
                }
            }

            do {
                try process.run()
                if let payload {
                    inputPipe.fileHandleForWriting.write(payload)
                }
                inputPipe.fileHandleForWriting.closeFile()
            } catch {
                currentProcess = nil
                continuation.resume(throwing: error)
            }
        }
    }

    private func locateRunner(named name: String) throws -> URL {
        let fileManager = FileManager.default
        for root in AppPaths.projectRootCandidates() {
            let runner = root
                .appendingPathComponent("script", isDirectory: true)
                .appendingPathComponent(name)
            if fileManager.fileExists(atPath: runner.path) {
                return runner
            }
        }

        throw BrowserAutomationError.failed("Could not find script/\(name).")
    }
}

enum ChromeLiveStatus {
    case unknown
    case checking
    case connected
    case missing
    case running
}

private final class ProcessHandleBox: @unchecked Sendable {
    let process: Process

    init(_ process: Process) {
        self.process = process
    }
}
