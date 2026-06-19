import SwiftUI

struct CommandComposerView: View {
    @Environment(CommandStore.self) private var commands
    @Environment(SpeechStore.self) private var speech
    @Environment(AppActionService.self) private var actions
    @Environment(OpenAIPlannerService.self) private var planner
    @Environment(RealtimeWebRTCService.self) private var realtime

    var body: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField("Ask it to do something on your Mac", text: Bindable(commands).currentCommand, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...4)
                .font(.callout)
                .padding(.vertical, 10)
                .onSubmit {
                    runQueuedCommand()
                }

            Button {
                runQueuedCommand()
            } label: {
                ZStack {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 25, weight: .semibold))
                        .foregroundStyle(sendTint)
                        .opacity(planner.isPlanning ? 0 : 1)

                    if planner.isPlanning {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
                .frame(width: 28, height: 28)
            }
            .disabled(isSendDisabled)
            .buttonStyle(.borderless)
            .help(buttonTitle)
            .keyboardShortcut(.return, modifiers: [.command])
        }
        .padding(.leading, 14)
        .padding(.trailing, 10)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(.quaternary)
        }
    }

    private var buttonTitle: String {
        if realtime.isConnected { return "Send" }
        return planner.isPlanning ? "Planning" : "Run"
    }

    private var isSendDisabled: Bool {
        commands.currentCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || planner.isPlanning || actions.isExecutingAction
    }

    private var sendTint: Color {
        isSendDisabled ? .secondary : .accentColor
    }

    private func runQueuedCommand() {
        guard let command = commands.enqueueCommand() else { return }
        Task {
            await execute(command)
        }
    }

    private func execute(_ command: String) async {
        if realtime.isConnected {
            commands.recordActivity(title: "Sent to Realtime", detail: command, status: .safe, kind: .queued, source: "Realtime")
            await realtime.sendTextCommand(command)
            return
        }

        let plan = await planner.plan(command: command)
        let source = commands.actionSource(for: plan)
        commands.recordActivity(title: "Planned \(plan.action.rawValue)", detail: plan.rationale, status: risk(for: plan), kind: .planned, source: source)
        commands.recordActivity(title: "Running \(plan.action.rawValue)", detail: plan.spokenText, status: .confirm, kind: .running, source: source)
        let result = await actions.execute(plan: plan, safetyMode: commands.safetyMode)
        commands.recordActivity(
            title: result.succeeded ? "Manual command executed" : "Manual command blocked",
            detail: result.detail,
            status: result.succeeded ? .safe : .confirm,
            kind: result.succeeded ? .completed : .blocked,
            source: source
        )
        speech.speak(result.spokenText)
    }

    private func risk(for plan: PlannedAction) -> ToolRisk {
        switch plan.risk {
        case "safe": .safe
        case "confirm": .confirm
        default: .handoff
        }
    }
}
