import SwiftUI

struct ContentView: View {
    @Environment(PermissionStore.self) private var permissions
    @Environment(CommandStore.self) private var commands
    @Environment(SpeechStore.self) private var speech
    @Environment(AppActionService.self) private var actions
    @Environment(ChromeLiveAutomationService.self) private var chromeLive
    @Environment(VoiceCommandService.self) private var voice
    @Environment(RealtimeWebRTCService.self) private var realtime
    @Environment(OpenAIPlannerService.self) private var planner
    @Environment(\.scenePhase) private var scenePhase
    @State private var selection: SidebarSelection?
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SessionSidebarView(selection: $selection)
                .navigationSplitViewColumnWidth(min: 248, ideal: 276, max: 330)
        } detail: {
            detailView
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .navigationTitle(navigationTitle)
        }
        .overlay {
            RealtimeWebRTCBridgeView()
                .frame(width: 1, height: 1)
                .opacity(0.01)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    permissions.refresh()
                    Task {
                        await chromeLive.refreshStatus()
                    }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Refresh demo readiness")

                Button {
                    actions.cancelCurrentAction(reason: "User pressed Stop.")
                    Task {
                        await realtime.stopAssistantAndCancelAction()
                    }
                } label: {
                    Image(systemName: "stop.fill")
                }
                .disabled(!realtime.isConnected && !actions.isExecutingAction)
                .help("Stop current response or action")
            }
        }
        .onChange(of: voice.lastCommandID) { _, _ in
            Task {
                await handleRecognizedCommand(voice.lastHeard)
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                permissions.refresh()
            }
        }
        .onChange(of: commands.currentSessionID) { _, newValue in
            if case .session = selection {
                selection = .session(newValue)
            }
        }
        .onAppear {
            if selection == nil {
                selection = .session(commands.currentSessionID)
            }
        }
        .task {
            await permissions.requestStartupPermissionsIfNeeded()
            await chromeLive.refreshStatus()
            await monitorPermissions()
        }
    }

    @ViewBuilder
    private var detailView: some View {
        switch selection ?? .session(commands.currentSessionID) {
        case .session:
            ControlDashboardView()
        case .permissions:
            PermissionsView()
        case .activity:
            ActivityView()
        }
    }

    private var navigationTitle: String {
        switch selection ?? .session(commands.currentSessionID) {
        case .session:
            return commands.currentSession.title
        case .permissions:
            return "Permissions"
        case .activity:
            return "Activity"
        }
    }

    private func toggleRealtime() async {
        if realtime.isConnected {
            realtime.disconnect()
            commands.recordActivity(
                title: "Realtime disconnected",
                detail: "Voice session stopped.",
                status: .safe,
                kind: .cancelled,
                source: "Realtime"
            )
            return
        }

        await refreshWorkspaceContext()
        await realtime.setWorkspaceContext(commands.activeWorkspaceContext)
        await realtime.connect(
            toolExecutor: { plan in
                let result = await actions.execute(plan: plan, safetyMode: commands.safetyMode)
                await refreshWorkspaceContextIfNeeded(after: plan, result: result, goal: plan.text)
                return result
            },
            actionCanceller: { reason in
                actions.cancelCurrentAction(reason: reason)
            },
            activityRecorder: { title, detail, status in
                commands.recordActivity(title: title, detail: detail, status: status)
            }
        )
    }

    private func monitorPermissions() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(2))
            permissions.refresh()
        }
    }

    private func toggleListening() async {
        if voice.isListening {
            voice.stop()
            commands.recordActivity(
                title: "Listening paused",
                detail: "Native dictation stopped.",
                status: .safe,
                kind: .cancelled,
                source: "Voice"
            )
            speech.speak("Listening paused.")
        } else {
            await voice.start()
            commands.recordActivity(
                title: "Listening started",
                detail: "Free-form native dictation is active.",
                status: .safe,
                kind: .running,
                source: "Voice"
            )
            speech.speak("Listening.")
        }
    }

    private func handleRecognizedCommand(_ command: String) async {
        guard !command.isEmpty else { return }
        commands.recordActivity(title: "Voice transcript", detail: command, status: .safe, kind: .transcript, source: "Voice")
        await refreshWorkspaceContext()
        let plan = await planner.plan(command: command, context: commands.activeWorkspaceContext)
        let source = commands.actionSource(for: plan)
        commands.recordActivity(title: "Planned \(plan.action.rawValue)", detail: plan.rationale, status: risk(for: plan), kind: .planned, source: source)
        commands.recordActivity(title: "Running \(plan.action.rawValue)", detail: plan.spokenText, status: .confirm, kind: .running, source: source)
        let result = await actions.execute(plan: plan, safetyMode: commands.safetyMode)
        await refreshWorkspaceContextIfNeeded(after: plan, result: result, goal: command)
        commands.recordActivity(
            title: result.succeeded ? "Voice command executed" : "Voice command blocked",
            detail: result.detail,
            status: result.succeeded ? .safe : .confirm,
            kind: result.succeeded ? .completed : .blocked,
            source: source
        )
        speech.speak(result.spokenText)
    }

    private func refreshWorkspaceContext() async {
        guard let context = await chromeLive.refreshActiveContext() else { return }
        commands.updateActiveWorkspace(context)
        await realtime.setWorkspaceContext(context)
    }

    private func refreshWorkspaceContextIfNeeded(after plan: PlannedAction, result: ActionResult, goal: String?) async {
        guard result.succeeded else { return }
        guard shouldRefreshWorkspace(after: plan) else { return }
        if let context = await chromeLive.refreshActiveContext() {
            commands.updateActiveWorkspace(context)
        }
        commands.noteWorkspaceGoal(goal)
        await realtime.setWorkspaceContext(commands.activeWorkspaceContext)
    }

    private func shouldRefreshWorkspace(after plan: PlannedAction) -> Bool {
        switch plan.action {
        case .runBrowserTask, .openURL, .newTab, .browserBack, .browserForward, .switchTab, .findTab:
            true
        default:
            false
        }
    }

    private func risk(for plan: PlannedAction) -> ToolRisk {
        switch plan.risk {
        case "safe": .safe
        case "confirm": .confirm
        default: .handoff
        }
    }
}
