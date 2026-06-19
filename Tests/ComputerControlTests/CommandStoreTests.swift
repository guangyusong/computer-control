import XCTest
@testable import ComputerControl

final class CommandStoreTests: XCTestCase {
    func testSelectingSessionDoesNotRecordActivity() {
        let store = makeStore()
        let originalSessionID = store.currentSessionID
        let newSessionID = store.startNewSession()
        XCTAssertEqual(store.currentSessionID, newSessionID)

        let activityCount = store.activity.count
        store.selectSession(originalSessionID)

        XCTAssertEqual(store.currentSessionID, originalSessionID)
        XCTAssertEqual(store.activity.count, activityCount)
        XCTAssertFalse(store.visibleActivity.contains { $0.title == "Session continued" })
    }

    func testSessionBookkeepingIsHiddenFromVisibleActivity() {
        let store = makeStore()
        store.recordActivity(
            title: "Session continued",
            detail: "Internal selection bookkeeping.",
            status: .safe,
            kind: .system,
            source: "Session"
        )

        XCTAssertTrue(store.activity.contains { $0.title == "Session continued" })
        XCTAssertFalse(store.visibleActivity.contains { $0.title == "Session continued" })
    }

    func testContextEstimateLevels() {
        XCTAssertEqual(SessionContextEstimate(items: []).level, .fresh)

        let active = SessionContextEstimate(items: [
            ActivityItem(title: "Command", detail: String(repeating: "a", count: 8_000), status: .safe)
        ])
        XCTAssertEqual(active.level, .active)

        let long = SessionContextEstimate(items: makeItems(count: 80, detail: "small"))
        XCTAssertEqual(long.level, .long)

        let needsSummary = SessionContextEstimate(items: makeItems(count: 140, detail: "small"))
        XCTAssertEqual(needsSummary.level, .needsSummary)
    }

    func testHighImpactSafetyPolicyBlocksSend() {
        let plan = PlannedAction(
            action: .runBrowserTask,
            appName: nil,
            url: nil,
            text: "Click Send in Gmail",
            keys: nil,
            direction: nil,
            amount: nil,
            x: nil,
            y: nil,
            endX: nil,
            endY: nil,
            button: nil,
            elementLabel: nil,
            role: nil,
            menuPath: nil,
            scope: nil,
            tabQuery: nil,
            tabIndex: nil,
            maxSteps: nil,
            browserBackend: "live_chrome",
            browserProfileMode: nil,
            browserProfile: nil,
            spokenText: "I'll do that.",
            risk: "confirm",
            rationale: "User asked to send an email."
        )

        XCTAssertNotNil(ActionSafetyPolicy.blockedReason(for: plan, safetyMode: .powerUser))
    }

    private func makeStore() -> CommandStore {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ComputerControlTests-\(UUID().uuidString)", isDirectory: true)
        return CommandStore(
            historyURL: directory.appendingPathComponent("activity-history.json"),
            sessionsURL: directory.appendingPathComponent("sessions-history.json")
        )
    }

    private func makeItems(count: Int, detail: String) -> [ActivityItem] {
        (0..<count).map { index in
            ActivityItem(title: "Item \(index)", detail: detail, status: .safe)
        }
    }
}
