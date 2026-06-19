import Foundation
import Observation

@Observable
final class CommandStore {
    var selectedMode: AgentMode = .assist
    var safetyMode: SafetyMode {
        didSet {
            UserDefaults.standard.set(safetyMode.rawValue, forKey: Self.safetyModeDefaultsKey)
        }
    }
    var isListening = false
    var currentCommand = ""
    var sessions: [ControlSession]
    var currentSessionID: UUID

    var tools: [ToolCapability] = [
        ToolCapability(
            name: "Open and Focus Apps",
            description: "Launch apps, bring windows forward, switch active context.",
            status: "Prototype ready",
            risk: .safe,
            systemImage: "app.badge"
        ),
        ToolCapability(
            name: "Keyboard and Text Entry",
            description: "Type, set focused text, press shortcuts, and cancel running actions.",
            status: "Needs Accessibility",
            risk: .confirm,
            systemImage: "keyboard"
        ),
        ToolCapability(
            name: "Mouse and Scrolling",
            description: "Move, click, double-click, drag, and scroll by coordinates or focused context.",
            status: "Needs Accessibility",
            risk: .confirm,
            systemImage: "computermouse"
        ),
        ToolCapability(
            name: "Screen Observation",
            description: "Capture screenshots and feed visual state into computer-use loops.",
            status: "Needs Screen Recording",
            risk: .safe,
            systemImage: "rectangle.dashed"
        ),
        ToolCapability(
            name: "Accessibility Tree",
            description: "Inspect focused app UI, press labeled controls, and select menu items.",
            status: "Needs Accessibility",
            risk: .confirm,
            systemImage: "rectangle.3.group"
        ),
        ToolCapability(
            name: "Browser Control",
            description: "Use a managed Playwright browser for Gmail, page clicks, fields, and forms.",
            status: "Managed browser ready",
            risk: .confirm,
            systemImage: "globe"
        ),
        ToolCapability(
            name: "Visual Computer Use",
            description: "Run a screenshot/action loop for open-ended screen tasks with safety stops.",
            status: "Needs API access",
            risk: .handoff,
            systemImage: "eye"
        )
    ]

    var activity: [ActivityItem]

    private let historyURL: URL
    private let sessionsURL: URL
    private let maxHistoryCount = 500
    private let maxSessionCount = 80
    private static let safetyModeDefaultsKey = "ComputerControl.safetyMode"

    init(historyURL: URL? = nil, sessionsURL: URL? = nil) {
        self.historyURL = historyURL ?? Self.historyFileURL()
        self.sessionsURL = sessionsURL ?? Self.sessionsFileURL()
        safetyMode = Self.loadSafetyMode()
        let initialSessionID = UUID()
        sessions = []
        currentSessionID = initialSessionID

        if let savedActivity = Self.loadActivity(from: self.historyURL) {
            activity = savedActivity
        } else {
            activity = [
                ActivityItem(
                    kind: .system,
                    title: "Native app loaded",
                    detail: "Ready for typed commands or voice.",
                    status: .safe,
                    source: "App"
                )
            ]
        }

        let loadedSessions = Self.loadSessions(from: self.sessionsURL) ?? []
        let seedSession = loadedSessions.first ?? ControlSession(
            id: initialSessionID,
            title: "Current Session",
            summary: "Ready for typed commands or voice.",
            startedAt: activity.last?.timestamp ?? Date(),
            updatedAt: activity.first?.timestamp ?? Date(),
            activityCount: activity.count
        )
        sessions = loadedSessions.isEmpty ? [seedSession] : loadedSessions
        currentSessionID = sessions.first?.id ?? seedSession.id
        assignOrphanActivity(to: currentSessionID)
        refreshAllSessionMetadata()
        trimSessions()
        persistSessions()
        persistActivity()
    }

    var currentSession: ControlSession {
        sessions.first(where: { $0.id == currentSessionID }) ?? ControlSession(id: currentSessionID)
    }

    var currentSessionActivity: [ActivityItem] {
        visibleActivity.filter { $0.sessionId == currentSessionID }
    }

    var visibleActivity: [ActivityItem] {
        meaningfulSessionItems(from: activity)
    }

    var currentContextEstimate: SessionContextEstimate {
        contextEstimate(for: currentSessionID)
    }

    var recentSessionsForContinue: [ControlSession] {
        sessions
            .filter { $0.id != currentSessionID }
            .sorted { $0.updatedAt > $1.updatedAt }
            .prefix(8)
            .map(\.self)
    }

    func contextEstimate(for sessionID: UUID) -> SessionContextEstimate {
        let items = activity.filter { $0.sessionId == sessionID }
        return SessionContextEstimate(items: meaningfulSessionItems(from: items))
    }

    func toggleListening() {
        isListening.toggle()
        recordActivity(
            title: isListening ? "Listening started" : "Listening paused",
            detail: isListening ? "Voice session placeholder is active." : "Voice input is paused.",
            status: .safe,
            kind: isListening ? .running : .cancelled,
            source: "Voice"
        )
    }

    func recordActivity(
        title: String,
        detail: String,
        status: ToolRisk,
        kind: ActivityKind? = nil,
        source: String? = nil,
        sessionId: UUID? = nil
    ) {
        let resolvedKind = kind ?? inferredKind(title: title, detail: detail, status: status)
        let resolvedSessionID = sessionId ?? currentSessionID
        activity.insert(
            ActivityItem(
                sessionId: resolvedSessionID,
                kind: resolvedKind,
                title: title,
                detail: detail,
                status: status,
                source: source ?? inferredSource(title: title, detail: detail)
            ),
            at: 0
        )
        trimActivity()
        refreshAllSessionMetadata()
        refreshSessionMetadata(for: resolvedSessionID, latestTitle: title, latestDetail: detail, latestKind: resolvedKind)
        trimSessions()
        persistActivity()
        persistSessions()
    }

    func clearHistory() {
        activity = []
        sessions = [ControlSession(title: "New Session")]
        currentSessionID = sessions[0].id
        persistActivity()
        persistSessions()
    }

    @discardableResult
    func startNewSession() -> UUID {
        refreshSessionMetadata(for: currentSessionID)
        let session = ControlSession(title: "New Session")
        sessions.insert(session, at: 0)
        currentSessionID = session.id
        trimSessions()
        persistSessions()
        recordActivity(
            title: "New session started",
            detail: "Model context should start fresh. Persistent history remains available in Activity.",
            status: .safe,
            kind: .system,
            source: "Session",
            sessionId: session.id
        )
        return session.id
    }

    func selectSession(_ sessionID: UUID) {
        guard sessions.contains(where: { $0.id == sessionID }) else { return }
        currentSessionID = sessionID
    }

    func continueSession(_ sessionID: UUID) {
        selectSession(sessionID)
    }

    @discardableResult
    func enqueueCommand() -> String? {
        let trimmed = currentCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        recordActivity(
            title: "Command queued",
            detail: trimmed,
            status: selectedMode == .act ? .confirm : .safe,
            kind: .queued,
            source: "Typed"
        )
        currentCommand = ""
        return trimmed
    }

    func actionSource(for plan: PlannedAction) -> String {
        switch plan.action {
        case .runBrowserTask:
            if plan.browserBackend == "live_chrome" || plan.browserProfileMode == "existing_chrome" {
                return "Live Chrome"
            }
            return "Managed Browser"
        case .runVisualComputerTask:
            return "Visual Computer Use"
        case .screenshot:
            return "Screen Capture"
        case .inspectAccessibilityTree, .clickElement, .setFocusedText, .selectMenuItem:
            return "Accessibility"
        case .writeNote, .scroll, .click, .doubleClick, .moveMouse, .drag, .typeText, .pressKeys:
            return "Native Control"
        case .browserBack, .browserForward, .newTab, .closeTab, .switchTab, .findTab:
            return "Browser Shortcut"
        case .openApp, .openURL, .quitApp:
            return "macOS"
        case .speak:
            return "Assistant"
        case .unsupported:
            return "Planner"
        }
    }

    private func inferredKind(title: String, detail: String, status: ToolRisk) -> ActivityKind {
        let text = "\(title) \(detail)".localizedLowercase
        if text.contains("cancel") || text.contains("paused") || text.contains("disconnect") {
            return .cancelled
        }
        if text.contains("blocked") || text.contains("error") || status == .handoff {
            return .blocked
        }
        if text.contains("planned") {
            return .planned
        }
        if text.contains("transcript") {
            return .transcript
        }
        if text.contains("running") || text.contains("listening started") || text.contains("connecting") {
            return .running
        }
        if text.contains("queued") || text.contains("sent") || text.contains("drafted") {
            return .queued
        }
        if text.contains("executed") || text.contains("finished") || text.contains("opened") || status == .safe {
            return .completed
        }
        return .system
    }

    private func inferredSource(title: String, detail: String) -> String? {
        let text = "\(title) \(detail)".localizedLowercase
        if text.contains("browser") || text.contains("gmail") || text.contains("chrome") {
            return "Browser Agent"
        }
        if text.contains("visual") || text.contains("screenshot") || text.contains("screen") {
            return "Visual Computer Use"
        }
        if text.contains("accessibility") || text.contains(" ax ") {
            return "Accessibility"
        }
        if text.contains("realtime") {
            return "Realtime"
        }
        if text.contains("voice") || text.contains("listening") {
            return "Voice"
        }
        if text.contains("planned") || text.contains("planner") {
            return "Planner"
        }
        return nil
    }

    private func trimActivity() {
        if activity.count > maxHistoryCount {
            activity.removeLast(activity.count - maxHistoryCount)
        }
    }

    private func trimSessions() {
        sessions.sort { $0.updatedAt > $1.updatedAt }
        if sessions.count > maxSessionCount {
            let retained = Set(sessions.prefix(maxSessionCount).map(\.id))
            sessions.removeAll { !retained.contains($0.id) }
        }
    }

    private func assignOrphanActivity(to sessionID: UUID) {
        var changed = false
        for index in activity.indices where activity[index].sessionId == nil {
            activity[index].sessionId = sessionID
            changed = true
        }
        if changed {
            persistActivity()
        }
    }

    private func refreshSessionMetadata(
        for sessionID: UUID,
        latestTitle: String? = nil,
        latestDetail: String? = nil,
        latestKind: ActivityKind? = nil
    ) {
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        let items = activity.filter { $0.sessionId == sessionID }
        let summaryItems = meaningfulSessionItems(from: items)
        sessions[index].activityCount = summaryItems.count
        sessions[index].updatedAt = summaryItems.map(\.timestamp).max()
            ?? items.filter { $0.title == "New session started" }.map(\.timestamp).max()
            ?? sessions[index].startedAt
        sessions[index].summary = summary(for: summaryItems)

        if shouldRetitleSession(sessions[index]), let title = sessionTitle(latestTitle: latestTitle, latestDetail: latestDetail, latestKind: latestKind) {
            sessions[index].title = title
        }
    }

    private func refreshAllSessionMetadata() {
        let ids = sessions.map(\.id)
        for id in ids {
            refreshSessionMetadata(for: id)
        }
    }

    private func shouldRetitleSession(_ session: ControlSession) -> Bool {
        session.title == "New Session" || session.title == "Current Session"
    }

    private func meaningfulSessionItems(from items: [ActivityItem]) -> [ActivityItem] {
        items.filter { item in
            !(item.source == "Session" && (item.title == "Session continued" || item.title == "New session started"))
        }
    }

    private func sessionTitle(latestTitle: String?, latestDetail: String?, latestKind: ActivityKind?) -> String? {
        guard latestKind == .queued || latestKind == .transcript else { return nil }
        let candidate = (latestDetail?.isEmpty == false ? latestDetail : latestTitle)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let candidate, !candidate.isEmpty else { return nil }
        return Self.compact(candidate, limit: 52)
    }

    private func summary(for items: [ActivityItem]) -> String {
        guard !items.isEmpty else {
            return "No activity yet."
        }

        let newestFirst = items.sorted { $0.timestamp > $1.timestamp }
        let commands = newestFirst.filter { $0.kind == .queued || $0.kind == .transcript }
        let blocked = newestFirst.filter { $0.kind == .blocked }.count
        let completed = newestFirst.filter { $0.kind == .completed }.count
        let sources = Array(Set(newestFirst.compactMap(\.source))).sorted()
        let latestCommand = commands.first?.detail ?? commands.first?.title

        var parts: [String] = []
        if let latestCommand, !latestCommand.isEmpty {
            parts.append("Latest: \(Self.compact(latestCommand, limit: 90))")
        }
        parts.append("\(completed) done")
        if blocked > 0 {
            parts.append("\(blocked) blocked")
        }
        if !sources.isEmpty {
            parts.append("Sources: \(sources.prefix(4).joined(separator: ", "))")
        }
        return parts.joined(separator: " · ")
    }

    private static func compact(_ value: String, limit: Int) -> String {
        let normalized = value
            .replacingOccurrences(of: "\n", with: " ")
            .split(separator: " ")
            .joined(separator: " ")
        guard normalized.count > limit else { return normalized }
        let end = normalized.index(normalized.startIndex, offsetBy: max(0, limit - 1))
        return "\(normalized[..<end])…"
    }

    private func persistActivity() {
        do {
            let directory = historyURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(activity)
            try data.write(to: historyURL, options: [.atomic])
        } catch {
            assertionFailure("Could not persist activity history: \(error.localizedDescription)")
        }
    }

    private func persistSessions() {
        do {
            let directory = sessionsURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(sessions)
            try data.write(to: sessionsURL, options: [.atomic])
        } catch {
            assertionFailure("Could not persist sessions: \(error.localizedDescription)")
        }
    }

    private static func loadActivity(from url: URL) -> [ActivityItem]? {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }

        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode([ActivityItem].self, from: data)
        } catch {
            return nil
        }
    }

    private static func loadSessions(from url: URL) -> [ControlSession]? {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }

        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode([ControlSession].self, from: data)
        } catch {
            return nil
        }
    }

    private static func historyFileURL() -> URL {
        AppPaths.migratedSupportFile(named: "activity-history.json")
    }

    private static func loadSafetyMode() -> SafetyMode {
        guard let rawValue = UserDefaults.standard.string(forKey: safetyModeDefaultsKey),
              let mode = SafetyMode(rawValue: rawValue) else {
            return .powerUser
        }
        return mode
    }

    private static func sessionsFileURL() -> URL {
        AppPaths.migratedSupportFile(named: "sessions-history.json")
    }
}
