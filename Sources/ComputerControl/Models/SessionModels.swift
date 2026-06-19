import Foundation

enum SessionContextLevel: String, Codable, CaseIterable {
    case fresh
    case active
    case long
    case needsSummary

    var title: String {
        switch self {
        case .fresh: "Fresh"
        case .active: "Active"
        case .long: "Long"
        case .needsSummary: "Needs summary"
        }
    }

    var systemImage: String {
        switch self {
        case .fresh: "leaf"
        case .active: "circle.grid.cross"
        case .long: "text.append"
        case .needsSummary: "exclamationmark.triangle.fill"
        }
    }
}

struct SessionContextEstimate: Equatable {
    var eventCount: Int
    var characterCount: Int
    var approximateTokens: Int
    var level: SessionContextLevel

    init(items: [ActivityItem]) {
        eventCount = items.count
        characterCount = items.reduce(0) { partial, item in
            partial
                + item.title.count
                + item.detail.count
                + item.kind.title.count
                + item.status.rawValue.count
                + (item.source?.count ?? 0)
        }
        approximateTokens = characterCount / 4
        level = Self.level(eventCount: eventCount, approximateTokens: approximateTokens)
    }

    var detail: String {
        let tokenText = approximateTokens >= 1_000
            ? String(format: "%.1fk estimated tokens", Double(approximateTokens) / 1_000)
            : "\(approximateTokens) estimated tokens"
        let eventText = eventCount == 1 ? "1 event" : "\(eventCount) events"

        switch level {
        case .fresh:
            return "\(tokenText) across \(eventText). This session is still compact."
        case .active:
            return "\(tokenText) across \(eventText). This session is healthy."
        case .long:
            return "\(tokenText) across \(eventText). New Chat starts fresh when you want a reset."
        case .needsSummary:
            return "\(tokenText) across \(eventText). Start a new chat before a live demo if this feels noisy."
        }
    }

    private static func level(eventCount: Int, approximateTokens: Int) -> SessionContextLevel {
        if approximateTokens > 20_000 || eventCount >= 140 {
            return .needsSummary
        }
        if approximateTokens >= 8_000 || eventCount >= 80 {
            return .long
        }
        if approximateTokens >= 2_000 {
            return .active
        }
        return .fresh
    }
}

struct ControlSession: Identifiable, Codable, Equatable {
    var id: UUID
    var title: String
    var summary: String
    var startedAt: Date
    var updatedAt: Date
    var activityCount: Int

    init(
        id: UUID = UUID(),
        title: String = "New Session",
        summary: String = "No activity yet.",
        startedAt: Date = Date(),
        updatedAt: Date = Date(),
        activityCount: Int = 0
    ) {
        self.id = id
        self.title = title
        self.summary = summary
        self.startedAt = startedAt
        self.updatedAt = updatedAt
        self.activityCount = activityCount
    }

    var shortUpdatedAt: String {
        if Calendar.current.isDateInToday(updatedAt) {
            return Self.timeFormatter.string(from: updatedAt)
        }
        return Self.shortDateTimeFormatter.string(from: updatedAt)
    }

    var displaySubtitle: String {
        let count = activityCount == 1 ? "1 event" : "\(activityCount) events"
        return "\(count) · \(shortUpdatedAt)"
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter
    }()

    private static let shortDateTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()
}
