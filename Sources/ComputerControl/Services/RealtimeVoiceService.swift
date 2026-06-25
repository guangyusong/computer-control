@preconcurrency import AVFoundation
import Darwin
import Foundation
import Observation

enum RealtimeVoiceError: LocalizedError {
    case missingAPIKey
    case microphoneDenied
    case disconnected

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            "Add a .openai file at the project root or set OPENAI_API_KEY."
        case .microphoneDenied:
            "Microphone permission is required for Realtime voice."
        case .disconnected:
            "Realtime is not connected."
        }
    }
}

@Observable
@MainActor
final class RealtimeVoiceService {
    typealias ToolExecutor = @MainActor (PlannedAction) async -> ActionResult
    typealias ActionCanceller = @MainActor (String) -> Void
    typealias ActivityRecorder = @MainActor (String, String, ToolRisk) -> Void

    var isConnected = false
    var isListening = false
    var isResponding = false
    var status = "Realtime disconnected"
    var userTranscript = ""
    var assistantTranscript = ""
    var lastError: String?
    var lastToolCall: String?
    var lastServerEvent = "none"
    var audioChunksReceived = 0
    var audioBytesReceived = 0
    var audioStatus = "No audio received yet"
    var inputAudioStatus = "Mic off"
    var interactionMode: RealtimeInteractionMode = .presentation
    var workspaceContext: ActiveWorkspaceContext?

    private var socket: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var toolExecutor: ToolExecutor?
    private var actionCanceller: ActionCanceller?
    private var activityRecorder: ActivityRecorder?
    private var pendingArgumentsByCallID: [String: String] = [:]
    private var handledToolCallIDs = Set<String>()
    private let audioInput = RealtimeAudioInput()
    private let audioOutput = RealtimeAudioOutput()
    private var shouldStreamAudio = false
    private var suppressNextCancelError = false
    private var pendingFollowupResponse = false
    private var currentAssistantAudioItemID: String?
    private var currentAssistantAudioContentIndex = 0
    private var didTruncateCurrentAssistantAudio = false

    func connect(
        toolExecutor: @escaping ToolExecutor,
        actionCanceller: @escaping ActionCanceller,
        activityRecorder: @escaping ActivityRecorder
    ) async {
        guard !isConnected else { return }

        guard let apiKey = OpenAIConfiguration.apiKey() else {
            fail(RealtimeVoiceError.missingAPIKey.localizedDescription)
            return
        }

        guard await AVCaptureDevice.requestAccess(for: .audio) else {
            fail(RealtimeVoiceError.microphoneDenied.localizedDescription)
            return
        }

        self.toolExecutor = toolExecutor
        self.actionCanceller = actionCanceller
        self.activityRecorder = activityRecorder
        status = "Realtime connecting"
        lastError = nil
        userTranscript = ""
        assistantTranscript = ""

        do {
            try audioOutput.start()

            let socket = makeSocket(apiKey: apiKey)
            self.socket = socket
            socket.resume()
            isConnected = true
            status = "Configuring Realtime"

            receiveTask = Task { [weak self] in
                await self?.receiveLoop()
            }

            try await send(event: sessionUpdateEvent())
            shouldStreamAudio = true
            updateInputAudioStatus("Mic streaming")
            try startAudioInput()
            status = "Realtime listening"
            activityRecorder("Realtime connected", "Voice session is live.", .safe)
        } catch {
            fail(error.localizedDescription)
            disconnect()
        }
    }

    func disconnect() {
        receiveTask?.cancel()
        receiveTask = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        shouldStreamAudio = false
        audioInput.stop()
        audioOutput.stop()
        actionCanceller = nil
        updateInputAudioStatus("Mic off")
        isConnected = false
        isListening = false
        isResponding = false
        status = "Realtime disconnected"
    }

    func sendTextCommand(_ command: String) async {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        do {
            try await send(event: [
                "type": "conversation.item.create",
                "item": [
                    "type": "message",
                    "role": "user",
                    "content": [
                        [
                            "type": "input_text",
                            "text": trimmed
                        ]
                    ]
                ]
            ])
            try await send(event: responseCreateEvent())
            status = "Realtime processing"
        } catch {
            fail(error.localizedDescription)
        }
    }

    func setWorkspaceContext(_ context: ActiveWorkspaceContext?) async {
        workspaceContext = context
        guard isConnected else { return }

        do {
            try await send(event: [
                "type": "session.update",
                "session": [
                    "instructions": realtimeInstructions
                ]
            ])
            if let context {
                activityRecorder?("Workspace context", context.promptSummary, .safe)
            }
        } catch {
            activityRecorder?("Workspace context blocked", error.localizedDescription, .confirm)
        }
    }

    func playSpeakerTest() {
        do {
            try audioOutput.start()
            audioOutput.enqueuePCM16(Self.testTonePCM16())
            audioStatus = "Played local speaker test"
            activityRecorder?("Speaker test", "Played a local tone through the app audio engine.", .safe)
        } catch {
            fail(error.localizedDescription)
        }
    }

    func setInteractionMode(_ mode: RealtimeInteractionMode) {
        guard interactionMode != mode else { return }

        interactionMode = mode
        activityRecorder?("Audio mode", "\(mode.title): \(mode.detail)", .safe)

        guard isConnected else { return }

        Task { @MainActor in
            do {
                try await send(event: sessionUpdateEvent())
                status = "Realtime listening"
            } catch {
                fail(error.localizedDescription)
            }
        }
    }

    func stopAssistantAndCancelAction() async {
        let hadResponse = isResponding
        let playedMilliseconds = audioOutput.cancelQueuedAudio()

        actionCanceller?("User pressed Stop.")
        isResponding = false
        updateInputAudioStatus(isConnected ? "Mic streaming" : "Mic off")
        status = isConnected ? "Realtime listening" : "Realtime disconnected"
        audioStatus = playedMilliseconds > 0
            ? "Stopped assistant audio at \(playedMilliseconds) ms"
            : "Stopped assistant audio"
        activityRecorder?("Stop requested", "Stopped current assistant speech and native action if one was running.", .confirm)

        if isConnected, hadResponse {
            do {
                suppressNextCancelError = true
                try await send(event: ["type": "response.cancel"])
            } catch {
                fail(error.localizedDescription)
            }
        }

        await truncateCurrentAssistantAudio(playedMilliseconds: playedMilliseconds)
    }

    private func makeSocket(apiKey: String) -> URLSessionWebSocketTask {
        let model = ProcessInfo.processInfo.environment["REALTIME_MODEL"] ?? "gpt-realtime-2"
        var components = URLComponents(string: "wss://api.openai.com/v1/realtime")!
        components.queryItems = [URLQueryItem(name: "model", value: model)]

        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue(OpenAIConfiguration.safetyIdentifier(), forHTTPHeaderField: "OpenAI-Safety-Identifier")
        return URLSession.shared.webSocketTask(with: request)
    }

    private func sendAudio(_ audioData: Data) async {
        guard isConnected, shouldStreamAudio, !audioData.isEmpty else { return }

        if interactionMode == .presentation,
           isResponding || audioOutput.isLikelyPlayingResponseAudio() {
            updateInputAudioStatus("Mic paused while assistant speaks")
            return
        }

        updateInputAudioStatus("Mic streaming")

        do {
            try await send(event: [
                "type": "input_audio_buffer.append",
                "audio": audioData.base64EncodedString()
            ])
        } catch {
            fail(error.localizedDescription)
        }
    }

    private func send(event: [String: Any]) async throws {
        guard let socket else {
            throw RealtimeVoiceError.disconnected
        }

        let data = try JSONSerialization.data(withJSONObject: event)
        guard let text = String(data: data, encoding: .utf8) else {
            throw RealtimeVoiceError.disconnected
        }

        try await socket.send(.string(text))
    }

    private func startAudioInput() throws {
        guard shouldStreamAudio else { return }

        try audioInput.start { [weak self] audioData in
            Task { @MainActor [weak self] in
                await self?.sendAudio(audioData)
            }
        }
        isListening = true
    }

    private func receiveLoop() async {
        while !Task.isCancelled {
            guard let socket else { return }

            do {
                let message = try await socket.receive()

                switch message {
                case let .string(text):
                    await handleMessage(text)
                case let .data(data):
                    if let text = String(data: data, encoding: .utf8) {
                        await handleMessage(text)
                    }
                @unknown default:
                    break
                }
            } catch {
                guard !Task.isCancelled else { return }
                fail(error.localizedDescription)
                disconnect()
                return
            }
        }
    }

    private func handleMessage(_ text: String) async {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let event = object as? [String: Any],
              let type = event["type"] as? String else {
            return
        }
        lastServerEvent = type

        switch type {
        case "session.created":
            status = "Realtime session created"
        case "session.updated":
            status = "Realtime listening"
        case "input_audio_buffer.speech_started":
            if isResponding {
                if interactionMode.allowsBargeIn {
                    await handleBargeInStarted()
                }
                return
            }
            status = "Listening"
            userTranscript = ""
        case "input_audio_buffer.speech_stopped":
            status = "Processing"
        case "input_audio_buffer.committed":
            status = "Thinking"
        case "conversation.item.input_audio_transcription.delta":
            let delta = event["delta"] as? String ?? ""
            userTranscript += delta
        case "conversation.item.input_audio_transcription.completed":
            if let transcript = event["transcript"] as? String, !transcript.isEmpty {
                userTranscript = transcript
                activityRecorder?("You said", transcript, .safe)
                handleCancellationIntentIfNeeded(transcript)
            }
        case "response.created":
            isResponding = true
            suppressNextCancelError = false
            assistantTranscript = ""
            audioChunksReceived = 0
            audioBytesReceived = 0
            audioStatus = "Waiting for response audio"
            currentAssistantAudioItemID = nil
            currentAssistantAudioContentIndex = 0
            didTruncateCurrentAssistantAudio = false
            audioOutput.beginResponse()
            if interactionMode == .presentation {
                updateInputAudioStatus("Mic paused while assistant speaks")
            }
            status = "Assistant responding"
        case "response.output_item.added", "conversation.item.added":
            if let item = event["item"] as? [String: Any] {
                noteAssistantOutputItem(item)
            }
        case "response.content_part.added":
            if let contentIndex = intValue(event["content_index"]),
               let part = event["part"] as? [String: Any],
               ((part["type"] as? String)?.contains("audio") == true || currentAssistantAudioItemID != nil) {
                currentAssistantAudioContentIndex = contentIndex
            }
        case "response.output_audio.delta", "response.audio.delta":
            if let base64 = event["delta"] as? String,
               let audioData = Data(base64Encoded: base64) {
                audioChunksReceived += 1
                audioBytesReceived += audioData.count
                audioStatus = "Audio chunks: \(audioChunksReceived), bytes: \(audioBytesReceived)"
                audioOutput.enqueuePCM16(audioData)
            }
        case "response.output_audio.done", "response.audio.done":
            if audioChunksReceived == 0 {
                audioStatus = "Response finished with no audio chunks"
            }
        case "response.output_audio_transcript.delta", "response.audio_transcript.delta":
            assistantTranscript += event["delta"] as? String ?? ""
        case "response.output_audio_transcript.done", "response.audio_transcript.done":
            if let transcript = event["transcript"] as? String, !transcript.isEmpty {
                assistantTranscript = transcript
                activityRecorder?("Assistant", transcript, .safe)
            }
        case "response.output_text.delta":
            assistantTranscript += event["delta"] as? String ?? ""
        case "response.output_text.done":
            if let text = event["text"] as? String, !text.isEmpty {
                assistantTranscript = text
                activityRecorder?("Assistant text", text, .safe)
            }
        case "response.function_call_arguments.delta":
            guard let callID = event["call_id"] as? String else { return }
            pendingArgumentsByCallID[callID, default: ""] += event["delta"] as? String ?? ""
        case "response.function_call_arguments.done":
            guard let callID = event["call_id"] as? String else { return }
            if let arguments = event["arguments"] as? String {
                pendingArgumentsByCallID[callID] = arguments
            }
        case "conversation.item.done", "response.output_item.done":
            if let item = event["item"] as? [String: Any] {
                noteAssistantOutputItem(item)
                await handleCompletedItem(item)
            }
        case "conversation.item.truncated":
            audioStatus = "Interrupted audio was truncated"
        case "response.cancelled", "response.canceled":
            isResponding = false
            suppressNextCancelError = false
            updateInputAudioStatus(isConnected ? "Mic streaming" : "Mic off")
            status = "Realtime listening"
            audioStatus = "Assistant response interrupted"
        case "response.done":
            isResponding = false
            suppressNextCancelError = false
            updateInputAudioStatus(isConnected ? "Mic streaming" : "Mic off")
            if pendingFollowupResponse {
                pendingFollowupResponse = false
                do {
                    try await send(event: responseCreateEvent())
                    status = "Realtime processing"
                } catch {
                    fail(error.localizedDescription)
                }
            } else {
                if audioChunksReceived == 0, !assistantTranscript.isEmpty {
                    audioStatus = "Response had transcript but no audio chunks"
                }
                status = "Realtime listening"
            }
        case "error":
            let message = (event["error"] as? [String: Any])?["message"] as? String
                ?? "Realtime returned an error."
            if shouldSuppressCancelError(message) {
                suppressNextCancelError = false
                return
            }
            fail(message)
        default:
            break
        }
    }

    private func handleBargeInStarted() async {
        guard isConnected else { return }
        let playedMilliseconds = audioOutput.cancelQueuedAudio()
        isResponding = false
        status = "Interrupted"
        audioStatus = "Stopped assistant audio at \(playedMilliseconds) ms"
        updateInputAudioStatus("Mic streaming")
        activityRecorder?("Interrupted", "Stopped assistant speech because you started talking.", .safe)
        await truncateCurrentAssistantAudio(playedMilliseconds: playedMilliseconds)
    }

    private func truncateCurrentAssistantAudio(playedMilliseconds: Int) async {
        guard let itemID = currentAssistantAudioItemID,
              playedMilliseconds > 0,
              !didTruncateCurrentAssistantAudio else {
            return
        }

        didTruncateCurrentAssistantAudio = true

        do {
            try await send(event: [
                "type": "conversation.item.truncate",
                "item_id": itemID,
                "content_index": currentAssistantAudioContentIndex,
                "audio_end_ms": playedMilliseconds
            ])
            activityRecorder?(
                "Truncated assistant audio",
                "Kept the first \(playedMilliseconds) ms of the interrupted response in conversation state.",
                .safe
            )
        } catch {
            activityRecorder?("Audio truncation skipped", error.localizedDescription, .confirm)
        }
    }

    private func shouldSuppressCancelError(_ message: String) -> Bool {
        guard suppressNextCancelError else { return false }

        let normalized = message.localizedLowercase
        return normalized.contains("cancel") || normalized.contains("active response")
    }

    private func handleCancellationIntentIfNeeded(_ transcript: String) {
        let normalized = transcript
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .localizedLowercase
        guard isCancellationIntent(normalized) else { return }

        actionCanceller?("User interruption requested cancellation: \(transcript)")
        activityRecorder?("Cancel requested", transcript, .confirm)
    }

    private func isCancellationIntent(_ normalizedTranscript: String) -> Bool {
        let sanitized = normalizedTranscript.map { character in
            character.isLetter || character.isNumber || character == "'" ? character : " "
        }
        let searchable = " \(String(sanitized).split(separator: " ").joined(separator: " ")) "
        let phrases = [
            "stop",
            "cancel",
            "never mind",
            "nevermind",
            "don't do that",
            "do not do that",
            "abort",
            "pause"
        ]
        return phrases.contains { phrase in
            searchable.contains(" \(phrase) ")
        }
    }

    private func noteAssistantOutputItem(_ item: [String: Any]) {
        guard let id = item["id"] as? String else { return }

        let type = item["type"] as? String
        let role = item["role"] as? String
        guard type == "message" || role == "assistant" else { return }

        currentAssistantAudioItemID = id
    }

    private func intValue(_ value: Any?) -> Int? {
        if let intValue = value as? Int {
            return intValue
        }

        if let number = value as? NSNumber {
            return number.intValue
        }

        return nil
    }

    private func handleCompletedItem(_ item: [String: Any]) async {
        guard item["type"] as? String == "function_call",
              item["name"] as? String == "run_computer_action" else {
            return
        }

        let callID = item["call_id"] as? String ?? item["id"] as? String ?? UUID().uuidString
        guard !handledToolCallIDs.contains(callID) else { return }
        handledToolCallIDs.insert(callID)

        let arguments = item["arguments"] as? String
            ?? pendingArgumentsByCallID[callID]
            ?? "{}"

        let plan: PlannedAction
        do {
            guard let data = arguments.data(using: .utf8) else {
                throw RealtimeVoiceError.disconnected
            }
            plan = try JSONDecoder().decode(PlannedAction.self, from: data)
        } catch {
            await sendToolOutput(
                callID: callID,
                result: ActionResult(
                    succeeded: false,
                    spokenText: "I could not understand the requested computer action.",
                    detail: error.localizedDescription
                )
            )
            return
        }

        lastToolCall = plan.action.rawValue
        activityRecorder?("Realtime tool", plan.rationale, risk(for: plan))

        guard let toolExecutor else {
            await sendToolOutput(
                callID: callID,
                result: ActionResult(
                    succeeded: false,
                    spokenText: "No native action executor is connected.",
                    detail: "Missing tool executor."
                )
            )
            return
        }

        let result = await toolExecutor(plan)
        activityRecorder?(
            result.succeeded ? "Native action executed" : "Native action blocked",
            result.detail,
            result.succeeded ? .safe : .confirm
        )
        await sendToolOutput(callID: callID, result: result)
    }

    private func sendToolOutput(callID: String, result: ActionResult) async {
        let output: [String: Any] = [
            "ok": result.succeeded,
            "spoken": result.spokenText,
            "detail": result.detail
        ]
        let outputData = (try? JSONSerialization.data(withJSONObject: output)) ?? Data("{}".utf8)
        let outputText = String(data: outputData, encoding: .utf8) ?? "{}"

        do {
            try await send(event: [
                "type": "conversation.item.create",
                "item": [
                    "type": "function_call_output",
                    "call_id": callID,
                    "output": outputText
                ]
            ])
            if isResponding {
                pendingFollowupResponse = true
            } else {
                try await send(event: responseCreateEvent())
            }
        } catch {
            fail(error.localizedDescription)
        }
    }

    private func responseCreateEvent() -> [String: Any] {
        [
            "type": "response.create",
            "response": [
                "output_modalities": ["audio"],
                "audio": [
                    "output": [
                        "format": [
                            "type": "audio/pcm",
                            "rate": 24_000
                        ]
                    ]
                ]
            ]
        ]
    }

    private func sessionUpdateEvent() -> [String: Any] {
        let voice = ProcessInfo.processInfo.environment["REALTIME_VOICE"] ?? "marin"
        let transcriptionModel = ProcessInfo.processInfo.environment["REALTIME_TRANSCRIPTION_MODEL"] ?? "whisper-1"

        return [
            "type": "session.update",
            "session": [
                "type": "realtime",
                "instructions": realtimeInstructions,
                "audio": [
                    "input": [
                        "format": [
                            "type": "audio/pcm",
                            "rate": 24_000
                        ],
                        "transcription": [
                            "model": transcriptionModel
                        ],
                        "turn_detection": [
                            "type": "server_vad",
                            "threshold": 0.5,
                            "prefix_padding_ms": 300,
                            "silence_duration_ms": 500,
                            "create_response": true,
                            "interrupt_response": interactionMode.allowsBargeIn
                        ]
                    ],
                    "output": [
                        "format": [
                            "type": "audio/pcm",
                            "rate": 24_000
                        ],
                        "voice": voice
                    ]
                ],
                "tools": [
                    [
                        "type": "function",
                        "name": "run_computer_action",
                        "description": "Execute one native Mac action requested by the user.",
                        "parameters": actionSchema
                    ]
                ],
                "tool_choice": "auto"
            ]
        ]
    }

    private var realtimeInstructions: String {
        """
        You are a native Mac voice control assistant. Talk naturally and briefly.
        When the user asks to control apps, browsers, tabs, mouse, keyboard, scrolling, screenshots, or visible UI elements, call run_computer_action with exactly one native action.
        For requests to open a website or browser tab in Chrome, use open_url with appName set to Google Chrome and url set to the requested website.
        If the user asks for a blank Chrome tab with no website, use open_url with appName set to Google Chrome and url set to chrome://newtab.
        For requests to create or write a note in Notes, use write_note with text set to the full note content.
        For Gmail, email drafts, clicking Compose, clicking browser page elements, and filling browser forms, prefer run_browser_task.
        For run_browser_task, set browserBackend to live_chrome by default. Use browserBackend managed only when the user explicitly asks for the isolated managed browser fallback.
        Keep browserProfileMode compatible with browserBackend: existing_chrome for live_chrome, managed for managed.
        Prefer browser_* and accessibility actions over raw coordinate clicks when a semantic action is available.
        Use inspect_accessibility_tree or screenshot when you need to understand what is on screen before acting.
        Use run_visual_computer_task for open-ended tasks that require seeing the screen and performing multiple UI actions.
        Do not say a computer action happened until the tool result says ok is true.
        If the user asks to send, submit, purchase, authenticate, delete, or expose sensitive data, ask for confirmation before taking the write action.
        Do not invent permission state. If typing or keyboard control is blocked, explain that Accessibility permission is needed.
        \(workspaceInstructions)
        """
    }

    private var workspaceInstructions: String {
        guard let workspaceContext else {
            return "No active workspace context is currently known. If the user uses ambiguous language, inspect the current app, browser tab, or screen before opening a new workspace."
        }

        return """

        \(workspaceContext.promptSummary)
        Prefer continuing in this workspace for ambiguous follow-ups. If you need browser page context, call run_browser_task with browserBackend live_chrome and no URL so it uses the active tab.
        """
    }

    private var actionSchema: [String: Any] {
        PlannedAction.jsonSchema
    }

    private func risk(for plan: PlannedAction) -> ToolRisk {
        switch plan.risk {
        case "safe": .safe
        case "confirm": .confirm
        default: .handoff
        }
    }

    private func fail(_ message: String) {
        lastError = message
        status = "Realtime error"
        activityRecorder?("Realtime error", message, .handoff)
    }

    private func updateInputAudioStatus(_ status: String) {
        if inputAudioStatus != status {
            inputAudioStatus = status
        }
    }

    private nonisolated static func testTonePCM16() -> Data {
        let sampleRate = 24_000
        let duration = 0.35
        let frequency = 660.0
        let frameCount = Int(Double(sampleRate) * duration)
        var data = Data(capacity: frameCount * 2)

        for frame in 0..<frameCount {
            let fadeIn = min(1.0, Double(frame) / 480.0)
            let fadeOut = min(1.0, Double(frameCount - frame) / 480.0)
            let envelope = min(fadeIn, fadeOut)
            let value = sin(2.0 * Double.pi * frequency * Double(frame) / Double(sampleRate)) * 0.25 * envelope
            var sample = Int16(value * 32_767).littleEndian
            withUnsafeBytes(of: &sample) { data.append(contentsOf: $0) }
        }

        return data
    }
}

private final class RealtimeAudioInput: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let conversionQueue = DispatchQueue(label: "ComputerControl.RealtimeAudioInput")
    private var converter: AVAudioConverter?
    private let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 24_000,
        channels: 1,
        interleaved: false
    )!

    func start(onAudioData: @escaping @Sendable (Data) -> Void) throws {
        stop()

        let inputNode = engine.inputNode
        let sourceFormat = inputNode.outputFormat(forBus: 0)
        converter = AVAudioConverter(from: sourceFormat, to: targetFormat)

        inputNode.installTap(onBus: 0, bufferSize: 1_920, format: sourceFormat) { [weak self] buffer, _ in
            self?.conversionQueue.async { [weak self] in
                guard let self,
                      let pcmData = self.convertToPCM16(buffer) else {
                    return
                }
                onAudioData(pcmData)
            }
        }

        engine.prepare()
        try engine.start()
    }

    func stop() {
        if engine.isRunning {
            engine.stop()
        }
        engine.inputNode.removeTap(onBus: 0)
        converter = nil
    }

    private func convertToPCM16(_ buffer: AVAudioPCMBuffer) -> Data? {
        guard let converter else { return nil }

        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 512
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else {
            return nil
        }

        let inputProvider = ConverterInputProvider(buffer: buffer)
        var error: NSError?
        converter.convert(to: outputBuffer, error: &error) { _, status in
            if inputProvider.usedInput {
                status.pointee = .noDataNow
                return nil
            }

            inputProvider.usedInput = true
            status.pointee = .haveData
            return inputProvider.buffer
        }

        guard error == nil,
              outputBuffer.frameLength > 0,
              let channels = outputBuffer.floatChannelData else {
            return nil
        }

        let samples = channels[0]
        let frameCount = Int(outputBuffer.frameLength)
        var data = Data(capacity: frameCount * 2)

        for index in 0..<frameCount {
            let clipped = max(-1.0, min(1.0, samples[index]))
            var sample = Int16(clipped < 0 ? clipped * 32_768 : clipped * 32_767).littleEndian
            withUnsafeBytes(of: &sample) { data.append(contentsOf: $0) }
        }

        return data
    }
}

private final class ConverterInputProvider: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
    var usedInput = false

    init(buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }
}

private final class RealtimeAudioOutput: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let scheduleQueue = DispatchQueue(label: "ComputerControl.RealtimeAudioOutput")
    private var responseStartedAt: Date?
    private var scheduledFrames = 0
    private let outputFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 24_000,
        channels: 1,
        interleaved: false
    )!

    func start() throws {
        if !engine.attachedNodes.contains(player) {
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: outputFormat)
        }

        if !engine.isRunning {
            engine.prepare()
            try engine.start()
        }

        if !player.isPlaying {
            player.play()
        }
    }

    func beginResponse() {
        scheduleQueue.async { [weak self] in
            self?.responseStartedAt = nil
            self?.scheduledFrames = 0
        }
    }

    func enqueuePCM16(_ data: Data) {
        guard !data.isEmpty else { return }

        scheduleQueue.async { [weak self] in
            guard let self,
                  let buffer = self.makeBuffer(from: data) else {
                return
            }

            if self.responseStartedAt == nil {
                self.responseStartedAt = Date()
            }
            self.scheduledFrames += Int(buffer.frameLength)
            self.player.scheduleBuffer(buffer, completionHandler: nil)
            if !self.player.isPlaying {
                self.player.play()
            }
        }
    }

    func stop() {
        scheduleQueue.sync {
            player.stop()
            responseStartedAt = nil
            scheduledFrames = 0
        }

        if engine.isRunning {
            engine.stop()
        }
    }

    func cancelQueuedAudio() -> Int {
        scheduleQueue.sync {
            let playedMilliseconds = estimatedPlayedMillisecondsLocked()
            self.player.stop()
            responseStartedAt = nil
            scheduledFrames = 0
            if self.engine.isRunning {
                self.player.play()
            }
            return playedMilliseconds
        }
    }

    func isLikelyPlayingResponseAudio() -> Bool {
        scheduleQueue.sync {
            remainingResponseMillisecondsLocked() > 80
        }
    }

    func estimatedPlayedMilliseconds() -> Int {
        scheduleQueue.sync {
            estimatedPlayedMillisecondsLocked()
        }
    }

    private func remainingResponseMillisecondsLocked() -> Int {
        guard let responseStartedAt else { return 0 }

        let elapsedMilliseconds = Date().timeIntervalSince(responseStartedAt) * 1_000.0
        let scheduledMilliseconds = Double(scheduledFrames) / outputFormat.sampleRate * 1_000.0
        return max(0, Int(scheduledMilliseconds - elapsedMilliseconds))
    }

    private func estimatedPlayedMillisecondsLocked() -> Int {
        guard let responseStartedAt else { return 0 }

        let elapsedMilliseconds = Date().timeIntervalSince(responseStartedAt) * 1_000.0
        let scheduledMilliseconds = Double(scheduledFrames) / outputFormat.sampleRate * 1_000.0
        return max(0, Int(min(elapsedMilliseconds, scheduledMilliseconds)))
    }

    private func makeBuffer(from data: Data) -> AVAudioPCMBuffer? {
        let frameCount = data.count / 2
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(
                pcmFormat: outputFormat,
                frameCapacity: AVAudioFrameCount(frameCount)
              ),
              let channel = buffer.floatChannelData?[0] else {
            return nil
        }

        data.withUnsafeBytes { rawBuffer in
            let samples = rawBuffer.bindMemory(to: Int16.self)
            for index in 0..<frameCount {
                channel[index] = Float(Int16(littleEndian: samples[index])) / 32_768.0
            }
        }

        buffer.frameLength = AVAudioFrameCount(frameCount)
        return buffer
    }
}
