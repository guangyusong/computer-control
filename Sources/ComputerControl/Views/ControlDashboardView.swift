import SwiftUI

struct ControlDashboardView: View {
    @Environment(PermissionStore.self) private var permissions
    @Environment(CommandStore.self) private var commands
    @Environment(AppActionService.self) private var actions
    @Environment(ChromeLiveAutomationService.self) private var chromeLive
    @Environment(VoiceCommandService.self) private var voice
    @Environment(RealtimeWebRTCService.self) private var realtime
    @Environment(OpenAIPlannerService.self) private var planner

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            transcript

            if let error = realtime.lastError ?? planner.lastError {
                ErrorStrip(message: error)
                    .padding(.horizontal, 18)
                    .padding(.bottom, 8)
            }

            CommandComposerView()
                .padding(.horizontal, 18)
                .padding(.top, 10)
                .padding(.bottom, 14)
                .background(.regularMaterial)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(commands.currentSession.title)
                        .font(.headline)
                        .lineLimit(1)
                    Text(headerDetail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 12)

                headerActions
            }

            readinessBar
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 11)
        .background(.bar)
    }

    private var readinessBar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) {
                readinessChips
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    readinessChips
                }
            }
        }
    }

    @ViewBuilder
    private var readinessChips: some View {
        StatusPill(
            title: realtimeStatus,
            symbol: realtime.isConnected ? "waveform" : "mic.slash",
            tint: realtime.isConnected ? .green : .secondary,
            detail: realtime.isConnected ? realtime.inputAudioStatus : "Realtime voice is disconnected."
        )
        StatusPill(
            title: permissions.microphone == .granted ? "Mic" : "Mic needed",
            symbol: permissions.microphone == .granted ? "mic.fill" : "mic.slash.fill",
            tint: permissions.microphone == .granted ? .green : .orange,
            detail: "Microphone permission for voice input."
        )
        StatusPill(
            title: permissions.accessibility == .granted ? "Accessibility" : "AX needed",
            symbol: permissions.accessibility == .granted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill",
            tint: permissions.accessibility == .granted ? .green : .orange,
            detail: "Accessibility permission controls native apps."
        )
        StatusPill(
            title: permissions.screenRecording == .granted ? "Screen" : "Screen needed",
            symbol: permissions.screenRecording == .granted ? "rectangle.dashed.badge.record" : "rectangle.dashed",
            tint: permissions.screenRecording == .granted ? .green : .orange,
            detail: "Screen Recording enables screenshots and visual computer use."
        )
        StatusPill(
            title: chromeLive.statusTitle,
            symbol: "globe.badge.chevron.backward",
            tint: chromeLive.isConnected ? .green : .orange,
            detail: chromeLive.statusDetail
        )
        StatusPill(
            title: commands.currentContextEstimate.level.title,
            symbol: commands.currentContextEstimate.level.systemImage,
            tint: commands.currentContextEstimate.level.tint,
            detail: commands.currentContextEstimate.detail
        )
    }

    private var headerActions: some View {
        HStack(spacing: 6) {
            Button {
                Task {
                    await runDemoCheck()
                }
            } label: {
                Image(systemName: "checklist")
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(.borderless)
            .help("Check demo readiness")

            Button {
                realtime.playSpeakerTest()
            } label: {
                Image(systemName: "speaker.wave.2.fill")
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(.borderless)
            .help("Test speaker")

            Button {
                actions.cancelCurrentAction(reason: "User pressed Stop.")
                Task {
                    await realtime.stopAssistantAndCancelAction()
                }
            } label: {
                Image(systemName: "stop.fill")
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(.borderless)
            .disabled(!realtime.isConnected && !actions.isExecutingAction)
            .help("Stop current response or action")

            Button {
                Task {
                    await toggleRealtime()
                }
            } label: {
                Label(realtime.isConnected ? "Disconnect" : "Talk", systemImage: realtime.isConnected ? "stop.circle.fill" : "mic.fill")
            }
            .controlSize(.small)
            .keyboardShortcut("l", modifiers: [.command])
            .help(realtime.isConnected ? "Disconnect Realtime voice" : "Start Realtime voice")
        }
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if currentActivity.isEmpty {
                        EmptyConversationView()
                    } else {
                        ForEach(Array(currentActivity.prefix(80).reversed())) { item in
                            ActivityChatRow(item: item)
                                .id(item.id)
                        }
                    }

                    if !liveTranscript.isEmpty {
                        LiveTranscriptRow(text: liveTranscript)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 16)
                .frame(maxWidth: 880, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .background(Color(nsColor: .textBackgroundColor).opacity(0.18))
            .onChange(of: currentActivity.count) { _, _ in
                if let first = currentActivity.first {
                    withAnimation(.easeOut(duration: 0.16)) {
                        proxy.scrollTo(first.id, anchor: .bottom)
                    }
                }
            }
        }
    }

    private var realtimeStatus: String {
        if realtime.isResponding { return "Speaking" }
        if realtime.isConnecting { return "Connecting" }
        if realtime.isConnected { return "Listening" }
        return "Off"
    }

    private var headerDetail: String {
        if actions.isExecutingAction {
            return "Running \(actions.currentActionDescription)"
        }
        if planner.isPlanning {
            return "Planning command"
        }
        if realtime.isConnected {
            return "\(realtime.interactionMode.status) · \(realtime.inputAudioStatus)"
        }
        return "Voice, browser, Accessibility, and visual computer-use tools"
    }

    private var liveTranscript: String {
        if !realtime.userTranscript.isEmpty {
            return realtime.userTranscript
        }
        if !voice.liveTranscript.isEmpty {
            return voice.liveTranscript
        }
        return ""
    }

    private var currentActivity: [ActivityItem] {
        commands.currentSessionActivity
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

        await realtime.connect(
            toolExecutor: { plan in
                await actions.execute(plan: plan, safetyMode: commands.safetyMode)
            },
            actionCanceller: { reason in
                actions.cancelCurrentAction(reason: reason)
            },
            activityRecorder: { title, detail, status in
                commands.recordActivity(title: title, detail: detail, status: status)
            }
        )
    }

    private func runDemoCheck() async {
        permissions.refresh()
        await chromeLive.refreshStatus()
        commands.recordActivity(
            title: chromeLive.isConnected ? "Demo check passed" : "Chrome extension missing",
            detail: chromeLive.statusDetail,
            status: chromeLive.isConnected ? .safe : .confirm,
            kind: chromeLive.isConnected ? .completed : .blocked,
            source: "Live Chrome"
        )
    }
}

private struct StatusPill: View {
    var title: String
    var symbol: String
    var tint: Color
    var detail: String? = nil

    var body: some View {
        Label(title, systemImage: symbol)
            .font(.caption)
            .fontWeight(.medium)
            .foregroundStyle(tint)
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(tint.opacity(0.1), in: Capsule())
            .lineLimit(1)
            .help(detail ?? title)
    }
}

private struct ActivityChatRow: View {
    var item: ActivityItem

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: item.kind.systemImage)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(item.status.tint)
                .frame(width: 18, height: 18)
                .padding(.top, 10)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(item.title)
                        .font(.callout)
                        .fontWeight(.semibold)
                        .lineLimit(1)
                    Text(item.time)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Spacer()
                    if let source = item.source {
                        StatusChip(text: source, tint: .secondary)
                    }
                    StatusChip(text: item.kind.title, tint: item.status.tint)
                }

                Text(item.detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)

            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(.quaternary)
            }
        }
    }
}

private struct LiveTranscriptRow: View {
    var text: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "waveform")
                .foregroundStyle(.blue)
                .frame(width: 12)
                .padding(.top, 8)
            Text(text)
                .font(.callout)
                .foregroundStyle(.primary)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(Color.blue.opacity(0.1), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }
}

private struct EmptyConversationView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Ready")
                .font(.title3)
                .fontWeight(.semibold)
            Text("Voice or type a command.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(.top, 40)
    }
}

private struct ErrorStrip: View {
    var message: String

    var body: some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.callout)
            .foregroundStyle(.orange)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct StatusChip: View {
    var text: String
    var tint: Color

    var body: some View {
        Text(text)
            .font(.caption2)
            .fontWeight(.semibold)
            .foregroundStyle(tint)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(tint.opacity(0.1), in: Capsule())
            .lineLimit(1)
    }
}

private extension SessionContextLevel {
    var tint: Color {
        switch self {
        case .fresh: .green
        case .active: .blue
        case .long: .orange
        case .needsSummary: .red
        }
    }
}
