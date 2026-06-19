import SwiftUI

struct ActivityView: View {
    @Environment(CommandStore.self) private var commands
    @State private var searchText = ""
    @State private var selectedSessionID: UUID?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18, pinnedViews: []) {
                    if groupedActivity.isEmpty {
                        ContentUnavailableView("No matching activity", systemImage: "list.bullet.rectangle")
                            .frame(maxWidth: .infinity, minHeight: 280)
                    } else {
                        ForEach(groupedActivity) { group in
                            VStack(alignment: .leading, spacing: 10) {
                                Text(group.title)
                                    .font(.caption)
                                    .fontWeight(.semibold)
                                    .foregroundStyle(.secondary)
                                    .textCase(.uppercase)

                                VStack(spacing: 0) {
                                    ForEach(group.items) { item in
                                        ActivityHistoryRow(item: item)
                                        if item.id != group.items.last?.id {
                                            Divider()
                                                .padding(.leading, 42)
                                        }
                                    }
                                }
                                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .stroke(.quaternary)
                                }
                            }
                        }
                    }
                }
                .padding(20)
                .frame(maxWidth: 980, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
        }
        .navigationTitle("Activity")
        .searchable(text: $searchText, prompt: "Search history")
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Activity")
                    .font(.headline)
                Text(headerSubtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Picker("Session", selection: $selectedSessionID) {
                Text("All History").tag(UUID?.none)
                Text("Current Session").tag(Optional(commands.currentSessionID))
                ForEach(activityFilterSessions) { session in
                    Text(session.title).tag(Optional(session.id))
                }
            }
            .frame(width: 220)
            .labelsHidden()

            Button(role: .destructive) {
                commands.clearHistory()
                selectedSessionID = nil
            } label: {
                Label("Clear History", systemImage: "trash")
            }
            .disabled(commands.activity.isEmpty)
        }
        .controlSize(.small)
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(.bar)
    }

    private var activityFilterSessions: [ControlSession] {
        commands.sessions
            .filter { $0.id != commands.currentSessionID }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    private var headerSubtitle: String {
        if let selectedSessionID, let session = commands.sessions.first(where: { $0.id == selectedSessionID }) {
            return "\(session.activityCount) saved events · \(session.title)"
        }
        return "\(commands.visibleActivity.count) saved events across \(commands.sessions.count) sessions"
    }

    private var filteredActivity: [ActivityItem] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).localizedLowercase
        let scoped = selectedSessionID.map { sessionID in
            commands.visibleActivity.filter { $0.sessionId == sessionID }
        } ?? commands.visibleActivity

        guard !query.isEmpty else {
            return scoped
        }
        return scoped.filter { item in
            item.searchableText.contains(query)
        }
    }

    private var groupedActivity: [ActivitySectionGroup] {
        let grouped = Dictionary(grouping: filteredActivity, by: \.dayTitle)
        return grouped.map { title, items in
            ActivitySectionGroup(
                title: title,
                items: items.sorted { $0.timestamp > $1.timestamp }
            )
        }
        .sorted { first, second in
            (first.items.first?.timestamp ?? .distantPast) > (second.items.first?.timestamp ?? .distantPast)
        }
    }
}

private struct ActivitySectionGroup: Identifiable {
    var title: String
    var items: [ActivityItem]

    var id: String { title }
}

private struct ActivityHistoryRow: View {
    var item: ActivityItem

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: item.kind.systemImage)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(item.status.tint)
                .frame(width: 18, height: 18)
                .padding(.top, 2)

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
                        ActivityBadge(text: source, tint: .secondary)
                    }
                    Text(item.kind.title)
                        .font(.caption2)
                        .fontWeight(.semibold)
                        .foregroundStyle(item.status.tint)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(item.status.tint.opacity(0.1), in: Capsule())
                }

                Text(item.detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

private struct ActivityBadge: View {
    var text: String
    var tint: Color

    var body: some View {
        Text(text)
            .font(.caption2)
            .fontWeight(.semibold)
            .foregroundStyle(tint)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Color.secondary.opacity(0.12), in: Capsule())
            .lineLimit(1)
    }
}
