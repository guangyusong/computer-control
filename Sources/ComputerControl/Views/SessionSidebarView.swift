import AppKit
import SwiftUI

struct SessionSidebarView: View {
    @Environment(CommandStore.self) private var commands
    @Environment(AppActionService.self) private var actions
    @Environment(RealtimeWebRTCService.self) private var realtime
    @Binding var selection: SidebarSelection?
    @State private var searchText = ""

    var body: some View {
        List(selection: $selection) {
            if filteredSessions.isEmpty {
                Text("No chats found")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            } else {
                Section("Chats") {
                    ForEach(filteredSessions) { session in
                        SessionSidebarRow(
                            session: session,
                            isSelected: selection == .session(session.id)
                        )
                        .tag(SidebarSelection.session(session.id))
                        .help(session.summary)
                        .accessibilityLabel(session.title)
                        .accessibilityValue(session.summary)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .frame(minWidth: 248)
        .navigationTitle("Chats")
        .safeAreaInset(edge: .top, spacing: 0) {
            topControls
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            bottomControls
        }
        .onChange(of: selection) { _, newValue in
            guard case let .session(sessionID) = newValue else { return }
            continueSessionIfNeeded(sessionID)
        }
    }

    private var topControls: some View {
        VStack(spacing: 12) {
            brandBlock

            Button {
                startNewChat()
            } label: {
                Label("New Chat", systemImage: "plus")
                    .font(.callout)
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity, minHeight: 34)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .keyboardShortcut("n", modifiers: [.command])
            .accessibilityLabel("New Chat")

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search chats", text: $searchText)
                    .textFieldStyle(.plain)
            }
            .font(.callout)
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(.quaternary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 14)
        .padding(.bottom, 10)
        .background(.bar)
    }

    private var brandBlock: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 34, height: 34)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text("Computer Control")
                    .font(.headline)
                    .lineLimit(1)
                Text("\(commands.sessions.count) chats")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Computer Control")
    }

    private var bottomControls: some View {
        VStack(spacing: 0) {
            Divider()

            VStack(spacing: 2) {
                Button {
                    selection = .activity
                } label: {
                    UtilitySidebarRow(title: "Activity", systemImage: "list.bullet.rectangle", isSelected: selection == .activity)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Activity")

                Button {
                    selection = .permissions
                } label: {
                    UtilitySidebarRow(title: "Permissions", systemImage: "lock.shield", isSelected: selection == .permissions)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Permissions")

                SettingsLink {
                    UtilitySidebarRow(title: "Settings", systemImage: "gearshape", isSelected: false)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Settings")
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 10)
        }
        .background(.bar)
    }

    private var filteredSessions: [ControlSession] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).localizedLowercase
        let ordered = commands.sessions.sorted { $0.updatedAt > $1.updatedAt }
        guard !query.isEmpty else { return ordered }
        return ordered.filter { sessionMatches($0, query: query) }
    }

    private func sessionMatches(_ session: ControlSession, query: String) -> Bool {
        if session.title.localizedLowercase.contains(query) || session.summary.localizedLowercase.contains(query) {
            return true
        }

        return commands.visibleActivity.contains { item in
            item.sessionId == session.id && item.searchableText.contains(query)
        }
    }

    private func startNewChat() {
        actions.cancelCurrentAction(reason: "Starting a new chat.")
        if realtime.isConnected {
            realtime.disconnect()
        }
        let sessionID = commands.startNewSession()
        selection = .session(sessionID)
    }

    private func continueSessionIfNeeded(_ sessionID: UUID) {
        if sessionID != commands.currentSessionID {
            commands.selectSession(sessionID)
        }
    }
}

private struct SessionSidebarRow: View {
    var session: ControlSession
    var isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(session.title)
                    .font(.callout)
                    .fontWeight(isSelected ? .semibold : .regular)
                    .lineLimit(1)

                Spacer(minLength: 8)

                Text(session.shortUpdatedAt)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            Text(session.summary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

private struct UtilitySidebarRow: View {
    var title: String
    var systemImage: String
    var isSelected: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .medium))
                .frame(width: 18)

            Text(title)
                .font(.callout)
                .fontWeight(isSelected ? .semibold : .regular)

            Spacer()
        }
        .padding(.horizontal, 10)
        .frame(height: 34)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.accentColor.opacity(0.14))
            }
        }
    }
}
