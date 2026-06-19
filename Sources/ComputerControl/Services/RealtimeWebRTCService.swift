import AppKit
import AVFoundation
import Foundation
import Observation
import WebKit

enum RealtimeWebRTCError: LocalizedError {
    case missingAPIKey
    case microphoneDenied
    case bridgeUnavailable
    case badResponse(Int, String)
    case invalidSDP

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            "Add a .openai file at the project root or set OPENAI_API_KEY."
        case .microphoneDenied:
            "Microphone permission is required for WebRTC voice."
        case .bridgeUnavailable:
            "The WebRTC bridge is not ready yet."
        case let .badResponse(status, body):
            "OpenAI returned HTTP \(status): \(body)"
        case .invalidSDP:
            "Realtime returned an invalid WebRTC answer."
        }
    }
}

@Observable
@MainActor
final class RealtimeWebRTCService {
    typealias ToolExecutor = @MainActor (PlannedAction) async -> ActionResult
    typealias ActionCanceller = @MainActor (String) -> Void
    typealias ActivityRecorder = @MainActor (String, String, ToolRisk) -> Void

    var isConnected = false
    var isConnecting = false
    var isListening = false
    var isResponding = false
    var status = "WebRTC disconnected"
    var userTranscript = ""
    var assistantTranscript = ""
    var lastError: String?
    var lastToolCall: String?
    var lastServerEvent = "none"
    var audioStatus = "WebRTC audio idle"
    var inputAudioStatus = "Mic off"
    var interactionMode: RealtimeInteractionMode = .webRTC

    private weak var webView: WKWebView?
    private var isBridgeReady = false
    private var pendingConnect = false
    private var toolExecutor: ToolExecutor?
    private var actionCanceller: ActionCanceller?
    private var activityRecorder: ActivityRecorder?
    private var pendingArgumentsByCallID: [String: String] = [:]
    private var handledToolCallIDs = Set<String>()
    private var pendingFollowupResponse = false
    private var suppressNextCancelError = false

    func attach(webView: WKWebView) {
        guard self.webView !== webView else { return }
        self.webView = webView
        isBridgeReady = false
        webView.loadHTMLString(Self.bridgeHTML, baseURL: URL(string: "https://computer-control.local")!)
    }

    func handleBridgeMessage(_ body: Any) {
        guard let dictionary = body as? [String: Any],
              let kind = dictionary["kind"] as? String else {
            return
        }

        switch kind {
        case "ready":
            isBridgeReady = true
            audioStatus = "WebRTC bridge ready"
            if pendingConnect {
                pendingConnect = false
                Task { await startBridge() }
            }
        case "offer":
            guard let sdp = (dictionary["payload"] as? [String: Any])?["sdp"] as? String else {
                fail(RealtimeWebRTCError.invalidSDP.localizedDescription)
                return
            }
            Task {
                await answerOffer(sdp)
            }
        case "event":
            if let event = dictionary["payload"] as? [String: Any] {
                Task {
                    await handleRealtimeEvent(event)
                }
            }
        case "log":
            if let message = (dictionary["payload"] as? [String: Any])?["message"] as? String {
                activityRecorder?("WebRTC", message, .safe)
            }
        case "error":
            let message = (dictionary["payload"] as? [String: Any])?["message"] as? String
                ?? "WebRTC bridge error."
            fail(message)
        default:
            break
        }
    }

    func connect(
        toolExecutor: @escaping ToolExecutor,
        actionCanceller: @escaping ActionCanceller,
        activityRecorder: @escaping ActivityRecorder
    ) async {
        guard !isConnected, !isConnecting else { return }

        guard OpenAIConfiguration.apiKey() != nil else {
            fail(RealtimeWebRTCError.missingAPIKey.localizedDescription)
            return
        }

        guard await AVCaptureDevice.requestAccess(for: .audio) else {
            fail(RealtimeWebRTCError.microphoneDenied.localizedDescription)
            return
        }

        self.toolExecutor = toolExecutor
        self.actionCanceller = actionCanceller
        self.activityRecorder = activityRecorder
        lastError = nil
        userTranscript = ""
        assistantTranscript = ""
        pendingArgumentsByCallID.removeAll()
        handledToolCallIDs.removeAll()
        pendingFollowupResponse = false

        if !isBridgeReady {
            pendingConnect = true
            isConnecting = true
            status = "Preparing WebRTC bridge"
            return
        }

        await startBridge()
    }

    func disconnect() {
        pendingConnect = false
        isConnecting = false
        isConnected = false
        isListening = false
        isResponding = false
        toolExecutor = nil
        actionCanceller = nil
        status = "WebRTC disconnected"
        inputAudioStatus = "Mic off"
        audioStatus = "WebRTC audio idle"

        Task {
            try? await evaluate("window.realtimeBridge && window.realtimeBridge.stop()")
        }
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

    func playSpeakerTest() {
        Task {
            do {
                try await evaluate("window.realtimeBridge && window.realtimeBridge.speakerTest()")
                audioStatus = "Played WebRTC speaker test"
            } catch {
                NSSound.beep()
                audioStatus = "Played system speaker test"
            }
        }
    }

    func setInteractionMode(_ mode: RealtimeInteractionMode) {
        guard interactionMode != mode else { return }
        interactionMode = mode
        activityRecorder?("Audio mode", "\(mode.title): \(mode.detail)", .safe)
    }

    func stopAssistantAndCancelAction() async {
        actionCanceller?("User pressed Stop.")
        suppressNextCancelError = true

        do {
            try await send(event: ["type": "response.cancel"])
        } catch {
            fail(error.localizedDescription)
        }

        isResponding = false
        status = isConnected ? "Realtime listening" : "WebRTC disconnected"
        audioStatus = "Stopped assistant audio"
        activityRecorder?("Stop requested", "Stopped current assistant speech and native action if one was running.", .confirm)
    }

    private func startBridge() async {
        guard webView != nil else {
            fail(RealtimeWebRTCError.bridgeUnavailable.localizedDescription)
            return
        }

        do {
            isConnecting = true
            status = "Starting WebRTC"
            inputAudioStatus = "Opening mic"
            audioStatus = "Creating peer connection"
            try await evaluate("window.realtimeBridge.start()")
        } catch {
            fail(error.localizedDescription)
        }
    }

    private func answerOffer(_ sdp: String) async {
        do {
            status = "Creating Realtime call"
            audioStatus = "Exchanging WebRTC SDP"
            let answer = try await createRealtimeCall(offerSDP: sdp)
            try await evaluate("window.realtimeBridge.acceptAnswer(\(Self.javascriptStringLiteral(answer)))")
            status = "Connecting WebRTC"
        } catch {
            fail(error.localizedDescription)
        }
    }

    private func createRealtimeCall(offerSDP: String) async throws -> String {
        guard let key = OpenAIConfiguration.apiKey() else {
            throw RealtimeWebRTCError.missingAPIKey
        }

        let boundary = "Boundary-\(UUID().uuidString)"
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/realtime/calls")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue(OpenAIConfiguration.safetyIdentifier(), forHTTPHeaderField: "OpenAI-Safety-Identifier")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = try multipartBody(
            boundary: boundary,
            sdp: offerSDP,
            sessionJSON: sessionConfigurationJSON()
        )

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let body = String(data: data, encoding: .utf8) ?? ""

        guard (200..<300).contains(status) else {
            throw RealtimeWebRTCError.badResponse(status, body)
        }

        guard body.contains("m=audio") else {
            throw RealtimeWebRTCError.invalidSDP
        }

        return body
    }

    private func multipartBody(boundary: String, sdp: String, sessionJSON: String) throws -> Data {
        var data = Data()

        func append(_ string: String) {
            data.append(Data(string.utf8))
        }

        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"sdp\"\r\n")
        append("Content-Type: application/sdp\r\n\r\n")
        append(sdp)
        append("\r\n")
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"session\"\r\n")
        append("Content-Type: application/json\r\n\r\n")
        append(sessionJSON)
        append("\r\n")
        append("--\(boundary)--\r\n")

        return data
    }

    private func sessionConfigurationJSON() throws -> String {
        let data = try JSONSerialization.data(withJSONObject: sessionConfiguration())
        guard let text = String(data: data, encoding: .utf8) else {
            throw RealtimeWebRTCError.invalidSDP
        }
        return text
    }

    private func send(event: [String: Any]) async throws {
        let data = try JSONSerialization.data(withJSONObject: event)
        guard let text = String(data: data, encoding: .utf8) else {
            throw RealtimeWebRTCError.bridgeUnavailable
        }
        try await evaluate("window.realtimeBridge.sendEvent(\(text))")
    }

    private func evaluate(_ script: String) async throws {
        guard let webView else {
            throw RealtimeWebRTCError.bridgeUnavailable
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            webView.evaluateJavaScript(script) { _, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    private func handleRealtimeEvent(_ event: [String: Any]) async {
        guard let type = event["type"] as? String else { return }
        lastServerEvent = type

        switch type {
        case "bridge.data_channel.open":
            isConnected = true
            isConnecting = false
            isListening = true
            status = "Realtime WebRTC live"
            inputAudioStatus = "Mic streaming with echo cancellation"
            audioStatus = "WebRTC remote audio active"
            activityRecorder?("Realtime connected", "WebRTC voice session is live.", .safe)
        case "bridge.data_channel.closed":
            isConnected = false
            isConnecting = false
            isListening = false
            isResponding = false
            status = "WebRTC disconnected"
            inputAudioStatus = "Mic off"
        case "bridge.connection_state":
            if let state = event["state"] as? String {
                audioStatus = "WebRTC connection: \(state)"
            }
        case "input_audio_buffer.speech_started":
            inputAudioStatus = "Hearing you"
            if isResponding {
                status = "Interrupted"
                audioStatus = "WebRTC interruption handled"
            } else {
                status = "Listening"
            }
            userTranscript = ""
        case "input_audio_buffer.speech_stopped":
            inputAudioStatus = "Mic streaming with echo cancellation"
            status = "Processing"
        case "input_audio_buffer.committed":
            status = "Thinking"
        case "conversation.item.input_audio_transcription.delta":
            userTranscript += event["delta"] as? String ?? ""
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
            status = "Assistant responding"
            audioStatus = "Assistant audio playing through WebRTC"
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
                await handleCompletedItem(item)
            }
        case "response.cancelled", "response.canceled":
            isResponding = false
            suppressNextCancelError = false
            status = "Realtime listening"
            audioStatus = "Assistant response interrupted"
        case "response.done":
            isResponding = false
            if pendingFollowupResponse {
                pendingFollowupResponse = false
                do {
                    try await send(event: responseCreateEvent())
                    status = "Realtime processing"
                } catch {
                    fail(error.localizedDescription)
                }
            } else {
                status = "Realtime listening"
                audioStatus = "WebRTC remote audio active"
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
                throw RealtimeWebRTCError.bridgeUnavailable
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
                "output_modalities": ["audio"]
            ]
        ]
    }

    private func sessionConfiguration() -> [String: Any] {
        let model = ProcessInfo.processInfo.environment["REALTIME_MODEL"] ?? "gpt-realtime-2"
        let voice = ProcessInfo.processInfo.environment["REALTIME_VOICE"] ?? "marin"
        let transcriptionModel = ProcessInfo.processInfo.environment["REALTIME_TRANSCRIPTION_MODEL"] ?? "whisper-1"

        return [
            "type": "realtime",
            "model": model,
            "instructions": realtimeInstructions,
            "audio": [
                "input": [
                    "transcription": [
                        "model": transcriptionModel
                    ],
                    "turn_detection": [
                        "type": "server_vad",
                        "threshold": 0.5,
                        "prefix_padding_ms": 300,
                        "silence_duration_ms": 500,
                        "create_response": true,
                        "interrupt_response": true
                    ]
                ],
                "output": [
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
        """
    }

    private var actionSchema: [String: Any] {
        PlannedAction.jsonSchema
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

    private func risk(for plan: PlannedAction) -> ToolRisk {
        switch plan.risk {
        case "safe": .safe
        case "confirm": .confirm
        default: .handoff
        }
    }

    private func fail(_ message: String) {
        pendingConnect = false
        isConnecting = false
        isConnected = false
        isListening = false
        isResponding = false
        inputAudioStatus = "Mic off"
        lastError = message
        status = "WebRTC error"
        activityRecorder?("Realtime error", message, .handoff)
    }

    private static func javascriptStringLiteral(_ value: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [value])) ?? Data("[\"\"]".utf8)
        let arrayLiteral = String(data: data, encoding: .utf8) ?? "[\"\"]"
        return String(arrayLiteral.dropFirst().dropLast())
    }

    private nonisolated static let bridgeHTML = """
    <!doctype html>
    <html>
    <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <style>
        html, body { margin: 0; padding: 0; width: 1px; height: 1px; overflow: hidden; background: transparent; }
        audio { width: 1px; height: 1px; opacity: 0; }
      </style>
    </head>
    <body>
      <audio id="remoteAudio" autoplay playsinline></audio>
      <script>
        (() => {
          const post = (kind, payload = {}) => {
            try {
              window.webkit.messageHandlers.realtimeBridge.postMessage({ kind, payload });
            } catch (error) {
              console.error(error);
            }
          };

          const waitForIceGathering = (pc) => new Promise((resolve) => {
            if (pc.iceGatheringState === "complete") {
              resolve();
              return;
            }

            const timeout = setTimeout(resolve, 1500);
            pc.addEventListener("icegatheringstatechange", () => {
              if (pc.iceGatheringState === "complete") {
                clearTimeout(timeout);
                resolve();
              }
            });
          });

          window.realtimeBridge = {
            pc: null,
            dc: null,
            localStream: null,
            audioElement: document.getElementById("remoteAudio"),
            queuedEvents: [],

            async start() {
              await this.stop();
              post("log", { message: `WebRTC secure context: ${window.isSecureContext}` });

              const pc = new RTCPeerConnection();
              this.pc = pc;

              pc.ontrack = async (event) => {
                const [stream] = event.streams;
                this.audioElement.srcObject = stream;
                try {
                  await this.audioElement.play();
                  post("log", { message: "Remote assistant audio attached." });
                } catch (error) {
                  post("error", { message: `Remote audio playback failed: ${error.message}` });
                }
              };

              pc.onconnectionstatechange = () => {
                post("event", { type: "bridge.connection_state", state: pc.connectionState });
              };

              this.localStream = await navigator.mediaDevices.getUserMedia({
                audio: {
                  echoCancellation: true,
                  noiseSuppression: true,
                  autoGainControl: true
                },
                video: false
              });

              for (const track of this.localStream.getAudioTracks()) {
                pc.addTrack(track, this.localStream);
                post("log", {
                  message: `Mic track enabled. echoCancellation=${track.getSettings().echoCancellation ?? "unknown"}`
                });
              }

              const dc = pc.createDataChannel("oai-events");
              this.dc = dc;

              dc.onopen = () => {
                post("event", { type: "bridge.data_channel.open" });
                for (const queuedEvent of this.queuedEvents.splice(0)) {
                  dc.send(JSON.stringify(queuedEvent));
                }
              };

              dc.onclose = () => {
                post("event", { type: "bridge.data_channel.closed" });
              };

              dc.onerror = () => {
                post("error", { message: "Realtime data channel error." });
              };

              dc.onmessage = (message) => {
                try {
                  post("event", JSON.parse(message.data));
                } catch (error) {
                  post("error", { message: `Could not parse Realtime event: ${error.message}` });
                }
              };

              const offer = await pc.createOffer();
              await pc.setLocalDescription(offer);
              await waitForIceGathering(pc);
              post("offer", { sdp: pc.localDescription.sdp });
            },

            async acceptAnswer(answerSDP) {
              if (!this.pc) {
                throw new Error("Peer connection is missing.");
              }
              await this.pc.setRemoteDescription({ type: "answer", sdp: answerSDP });
            },

            sendEvent(event) {
              if (this.dc && this.dc.readyState === "open") {
                this.dc.send(JSON.stringify(event));
              } else {
                this.queuedEvents.push(event);
              }
            },

            async speakerTest() {
              const AudioContextClass = window.AudioContext || window.webkitAudioContext;
              const context = new AudioContextClass();
              const oscillator = context.createOscillator();
              const gain = context.createGain();
              oscillator.frequency.value = 660;
              gain.gain.setValueAtTime(0.001, context.currentTime);
              gain.gain.exponentialRampToValueAtTime(0.18, context.currentTime + 0.03);
              gain.gain.exponentialRampToValueAtTime(0.001, context.currentTime + 0.35);
              oscillator.connect(gain);
              gain.connect(context.destination);
              oscillator.start();
              oscillator.stop(context.currentTime + 0.38);
              post("log", { message: "Played WebRTC speaker test." });
            },

            async stop() {
              if (this.dc) {
                try { this.dc.close(); } catch (_) {}
                this.dc = null;
              }
              if (this.pc) {
                try { this.pc.close(); } catch (_) {}
                this.pc = null;
              }
              if (this.localStream) {
                for (const track of this.localStream.getTracks()) {
                  track.stop();
                }
                this.localStream = null;
              }
              this.queuedEvents = [];
              this.audioElement.srcObject = null;
            }
          };

          post("ready");
        })();
      </script>
    </body>
    </html>
    """
}
