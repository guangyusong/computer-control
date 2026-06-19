import ApplicationServices
import AppKit
import AVFoundation
import CoreGraphics
import Foundation
import Observation
import Speech

enum PermissionState: String {
    case granted = "Granted"
    case missing = "Missing"
    case unknown = "Unknown"
}

@Observable
@MainActor
final class PermissionStore {
    var accessibility: PermissionState = .unknown
    var screenRecording: PermissionState = .unknown
    var microphone: PermissionState = .unknown
    var automation: PermissionState = .unknown

    private var didRequestStartupPermissions = false

    init() {
        refresh()
    }

    var isReadyForComputerUse: Bool {
        accessibility == .granted && screenRecording == .granted
    }

    func refresh() {
        accessibility = AXIsProcessTrusted() ? .granted : .missing
        screenRecording = CGPreflightScreenCaptureAccess() ? .granted : .missing
        microphone = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized ? .granted : .missing
        automation = .unknown
    }

    func requestAccessibility() {
        let options = [
            "AXTrustedCheckOptionPrompt": true
        ] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        refresh()
    }

    func requestScreenRecording() {
        _ = CGRequestScreenCaptureAccess()
        refresh()
    }

    func requestMicrophone() {
        Task { [weak self] in
            _ = await Self.requestMicrophoneAccess()
            _ = await Self.requestSpeechAuthorization()
            await MainActor.run {
                self?.refresh()
            }
        }
    }

    func requestStartupPermissionsIfNeeded() async {
        guard !didRequestStartupPermissions else { return }
        didRequestStartupPermissions = true
        await requestCorePermissions()
    }

    func requestAllCorePermissions() {
        Task { [weak self] in
            await self?.requestCorePermissions()
        }
    }

    func openAccessibilitySettings() {
        openSystemSettings([
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility",
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility"
        ])
    }

    func openScreenRecordingSettings() {
        openSystemSettings([
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture",
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_ScreenCapture"
        ])
    }

    func openMicrophoneSettings() {
        openSystemSettings([
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone",
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Microphone"
        ])
    }

    func openAutomationSettings() {
        openSystemSettings([
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation",
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Automation"
        ])
    }

    func openPrivacySettings() {
        openSystemSettings([
            "x-apple.systempreferences:com.apple.preference.security",
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension"
        ])
    }

    private func requestCorePermissions() async {
        refresh()

        if microphone != .granted {
            _ = await Self.requestMicrophoneAccess()
            _ = await Self.requestSpeechAuthorization()
        }

        if accessibility != .granted {
            requestAccessibility()
        }

        if screenRecording != .granted {
            _ = CGRequestScreenCaptureAccess()
        }

        refresh()
    }

    private func openSystemSettings(_ urlStrings: [String]) {
        for urlString in urlStrings {
            guard let url = URL(string: urlString) else { continue }
            if NSWorkspace.shared.open(url) {
                return
            }
        }

        guard let fallback = URL(string: "x-apple.systempreferences:com.apple.preference.security") else {
            return
        }
        NSWorkspace.shared.open(fallback)
    }

    private nonisolated static func requestMicrophoneAccess() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    private nonisolated static func requestSpeechAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
    }
}
