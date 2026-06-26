import Foundation
import SwiftUI

enum WorkspaceSurfaceKind: String, Codable, Equatable {
    case browser
    case app
    case screen
    case unknown
}

struct ActiveWorkspaceContext: Codable, Equatable {
    var kind: WorkspaceSurfaceKind
    var source: String
    var appName: String?
    var title: String?
    var url: String?
    var detail: String?
    var lastGoal: String?
    var updatedAt: Date

    init(
        kind: WorkspaceSurfaceKind,
        source: String,
        appName: String? = nil,
        title: String? = nil,
        url: String? = nil,
        detail: String? = nil,
        lastGoal: String? = nil,
        updatedAt: Date = Date()
    ) {
        self.kind = kind
        self.source = source
        self.appName = appName
        self.title = title
        self.url = url
        self.detail = detail
        self.lastGoal = lastGoal
        self.updatedAt = updatedAt
    }

    var isBrowser: Bool {
        kind == .browser
    }

    var displayTitle: String {
        let candidate = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let candidate, !candidate.isEmpty {
            return Self.compact(candidate, limit: 42)
        }

        if let host {
            return host
        }

        return appName ?? source
    }

    var subtitle: String {
        if let host {
            return "\(source) - \(host)"
        }
        if let appName, appName != source {
            return "\(source) - \(appName)"
        }
        return source
    }

    var promptSummary: String {
        var lines = [
            "Current active workspace:",
            "- Surface: \(kind.rawValue)",
            "- Source: \(source)"
        ]

        if let appName, !appName.isEmpty {
            lines.append("- App: \(appName)")
        }
        if let title, !title.isEmpty {
            lines.append("- Title: \(title)")
        }
        if let url, !url.isEmpty {
            lines.append("- URL: \(url)")
        }
        if let detail, !detail.isEmpty {
            lines.append("- Detail: \(Self.compact(detail, limit: 240))")
        }
        if let lastGoal, !lastGoal.isEmpty {
            lines.append("- Last goal: \(Self.compact(lastGoal, limit: 180))")
        }

        lines.append("- Updated: \(Self.relativeDescription(for: updatedAt))")
        lines.append("For ambiguous follow-ups such as this, here, that page, current tab, continue, look up this address, click that, or fill this, prefer continuing in this workspace. Open a new tab or app only when the user explicitly asks or the current workspace is clearly irrelevant.")
        return lines.joined(separator: "\n")
    }

    var host: String? {
        guard let url,
              let components = URLComponents(string: url),
              let host = components.host,
              !host.isEmpty else {
            return nil
        }
        return host
    }

    var systemImage: String {
        switch kind {
        case .browser: "globe"
        case .app: "macwindow"
        case .screen: "rectangle.dashed"
        case .unknown: "questionmark.circle"
        }
    }

    var tint: Color {
        switch kind {
        case .browser: .blue
        case .app: .green
        case .screen: .orange
        case .unknown: .secondary
        }
    }

    private static func compact(_ value: String, limit: Int) -> String {
        let normalized = value
            .replacingOccurrences(of: "\n", with: " ")
            .split(separator: " ")
            .joined(separator: " ")
        guard normalized.count > limit else { return normalized }
        let end = normalized.index(normalized.startIndex, offsetBy: max(0, limit - 1))
        return "\(normalized[..<end])..."
    }

    private static func relativeDescription(for date: Date) -> String {
        let seconds = max(0, Int(Date().timeIntervalSince(date)))
        if seconds < 60 {
            return "\(seconds)s ago"
        }
        let minutes = seconds / 60
        if minutes < 60 {
            return "\(minutes)m ago"
        }
        let hours = minutes / 60
        if hours < 24 {
            return "\(hours)h ago"
        }
        return "\(hours / 24)d ago"
    }
}
