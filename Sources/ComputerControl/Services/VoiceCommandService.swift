import AVFoundation
import Foundation
import Observation
import Speech

@Observable
@MainActor
final class VoiceCommandService {
    private let controller = SpeechRecognitionController()
    private var commitTask: Task<Void, Never>?
    private var lastCommittedTranscript = ""

    var isListening = false
    var liveTranscript = ""
    var lastHeard = ""
    var lastCommandID = UUID()
    var status = "Mic disconnected"

    func start() async {
        guard !isListening else { return }

        do {
            try await SpeechRecognitionController.requestPermissions()
            try controller.start(
                onTranscript: { [weak self] transcript, isFinal in
                    Task { @MainActor in
                        self?.receive(transcript: transcript, isFinal: isFinal)
                    }
                },
                onError: { [weak self] message in
                    Task { @MainActor in
                        self?.status = message
                        self?.stop()
                    }
                }
            )
            isListening = true
            status = "Listening"
        } catch {
            status = error.localizedDescription
            stop()
        }
    }

    func stop() {
        commitTask?.cancel()
        commitTask = nil
        controller.stop()
        isListening = false
        status = "Mic disconnected"
    }

    private func receive(transcript: String, isFinal: Bool) {
        liveTranscript = transcript
        status = "Listening"
        scheduleCommit(transcript)

        if isFinal {
            commit(transcript)
        }
    }

    private func scheduleCommit(_ transcript: String) {
        commitTask?.cancel()
        commitTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.2))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.commit(transcript)
            }
        }
    }

    private func commit(_ transcript: String) {
        let cleaned = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, cleaned != lastCommittedTranscript else { return }
        lastCommittedTranscript = cleaned
        lastHeard = cleaned
        lastCommandID = UUID()
    }
}

private final class SpeechRecognitionController: NSObject, SFSpeechRecognizerDelegate {
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private let audioEngine = AVAudioEngine()
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var onTranscript: (@Sendable (String, Bool) -> Void)?
    private var onError: (@Sendable (String) -> Void)?

    override init() {
        super.init()
        recognizer?.delegate = self
    }

    static func requestPermissions() async throws {
        let speechStatus = await requestSpeechAuthorization()
        guard speechStatus == .authorized else {
            throw VoiceError.permission("Speech recognition permission is required.")
        }

        let micGranted = await AVCaptureDevice.requestAccess(for: .audio)
        guard micGranted else {
            throw VoiceError.permission("Microphone permission is required.")
        }
    }

    func start(
        onTranscript: @escaping @Sendable (String, Bool) -> Void,
        onError: @escaping @Sendable (String) -> Void
    ) throws {
        stop()

        guard recognizer?.isAvailable == true else {
            throw VoiceError.permission("Speech recognizer is unavailable.")
        }

        self.onTranscript = onTranscript
        self.onError = onError

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        recognitionRequest = request

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            request.append(buffer)
        }

        recognitionTask = recognizer?.recognitionTask(with: request) { [weak self] result, error in
            if let result {
                self?.onTranscript?(result.bestTranscription.formattedString, result.isFinal)
            }

            if let error {
                self?.onError?(error.localizedDescription)
            }
        }

        audioEngine.prepare()
        try audioEngine.start()
    }

    func stop() {
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest?.endAudio()
        recognitionRequest = nil

        if audioEngine.isRunning {
            audioEngine.stop()
        }

        audioEngine.inputNode.removeTap(onBus: 0)
    }

    nonisolated func speechRecognizer(_ speechRecognizer: SFSpeechRecognizer, availabilityDidChange available: Bool) {
        guard !available else { return }
        onError?("Speech recognizer is unavailable.")
    }

    private static func requestSpeechAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
    }
}

private enum VoiceError: LocalizedError {
    case permission(String)

    var errorDescription: String? {
        switch self {
        case let .permission(message): message
        }
    }
}
