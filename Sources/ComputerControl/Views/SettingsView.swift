import SwiftUI

struct SettingsView: View {
    @Environment(PermissionStore.self) private var permissions
    @Environment(CommandStore.self) private var commands
    @Environment(SpeechStore.self) private var speech
    @Environment(VoiceCommandService.self) private var voice

    var body: some View {
        Form {
            Section("Default Mode") {
                Picker("Mode", selection: Bindable(commands).selectedMode) {
                    ForEach(AgentMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
            }

            Section("Safety") {
                Picker("Safety mode", selection: Bindable(commands).safetyMode) {
                    ForEach(SafetyMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }

                Text(commands.safetyMode.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Permissions") {
                LabeledContent("Accessibility", value: permissions.accessibility.rawValue)
                LabeledContent("Screen Recording", value: permissions.screenRecording.rawValue)
            }

            Section("Speech") {
                LabeledContent("Command recognizer", value: voice.isListening ? "Listening" : "Paused")
                Button("Speak Test") {
                    speech.speak("Speech output is working.")
                }
                Button("Stop Speaking") {
                    speech.stop()
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}
