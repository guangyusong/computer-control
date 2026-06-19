import Foundation
import SwiftUI

enum AgentMode: String, CaseIterable, Identifiable {
    case observe
    case assist
    case act

    var id: String { rawValue }

    var title: String {
        switch self {
        case .observe: "Observe"
        case .assist: "Assist"
        case .act: "Act"
        }
    }

    var description: String {
        switch self {
        case .observe: "Read screen and narrate. No mouse, keyboard, or app changes."
        case .assist: "Prepare actions and ask before changing apps or sending data."
        case .act: "Run approved actions inside the active allowlist."
        }
    }
}

enum SafetyMode: String, Codable, CaseIterable, Identifiable {
    case powerUser
    case strictPreview

    var id: String { rawValue }

    var title: String {
        switch self {
        case .powerUser: "Power-user"
        case .strictPreview: "Strict preview"
        }
    }

    var detail: String {
        switch self {
        case .powerUser:
            "Broad local control is allowed, but high-impact actions still stop for explicit confirmation."
        case .strictPreview:
            "Typing, clicking, forms, and other write actions are blocked unless routed through safer demo paths."
        }
    }
}

enum RealtimeInteractionMode: String, CaseIterable, Identifiable, Hashable {
    case webRTC
    case presentation
    case bargeIn

    var id: String { rawValue }

    var title: String {
        switch self {
        case .webRTC: "WebRTC"
        case .presentation: "Presentation"
        case .bargeIn: "Barge-in"
        }
    }

    var status: String {
        switch self {
        case .webRTC: "Echo-cancelled"
        case .presentation: "Speaker-safe"
        case .bargeIn: "Interruptible"
        }
    }

    var detail: String {
        switch self {
        case .webRTC: "Mic and speaker run through WebRTC audio processing."
        case .presentation: "Mic pauses while the assistant speaks."
        case .bargeIn: "Mic stays live so speech can interrupt."
        }
    }

    var allowsBargeIn: Bool {
        self != .presentation
    }
}

enum ToolRisk: String, Codable, CaseIterable {
    case safe = "Safe"
    case confirm = "Confirm"
    case handoff = "Hand off"

    var tint: Color {
        switch self {
        case .safe: .green
        case .confirm: .orange
        case .handoff: .red
        }
    }
}

enum ActivityKind: String, Codable, CaseIterable {
    case queued
    case running
    case transcript
    case planned
    case completed
    case blocked
    case cancelled
    case system

    var title: String {
        switch self {
        case .queued: "Queued"
        case .running: "Running"
        case .transcript: "Transcript"
        case .planned: "Planned"
        case .completed: "Done"
        case .blocked: "Blocked"
        case .cancelled: "Cancelled"
        case .system: "System"
        }
    }

    var systemImage: String {
        switch self {
        case .queued: "clock"
        case .running: "arrow.triangle.2.circlepath"
        case .transcript: "text.bubble"
        case .planned: "wand.and.stars"
        case .completed: "checkmark.circle.fill"
        case .blocked: "exclamationmark.triangle.fill"
        case .cancelled: "stop.circle.fill"
        case .system: "gearshape"
        }
    }
}

struct ToolCapability: Identifiable {
    let id = UUID()
    var name: String
    var description: String
    var status: String
    var risk: ToolRisk
    var systemImage: String
}

struct ActivityItem: Identifiable, Codable, Equatable {
    var id: UUID
    var sessionId: UUID?
    var timestamp: Date
    var kind: ActivityKind
    var title: String
    var detail: String
    var status: ToolRisk
    var source: String?

    init(
        id: UUID = UUID(),
        sessionId: UUID? = nil,
        timestamp: Date = Date(),
        kind: ActivityKind = .system,
        title: String,
        detail: String,
        status: ToolRisk,
        source: String? = nil
    ) {
        self.id = id
        self.sessionId = sessionId
        self.timestamp = timestamp
        self.kind = kind
        self.title = title
        self.detail = detail
        self.status = status
        self.source = source
    }

    var time: String {
        if Calendar.current.isDateInToday(timestamp) {
            return Self.timeFormatter.string(from: timestamp)
        }
        return Self.shortDateTimeFormatter.string(from: timestamp)
    }

    var dayTitle: String {
        if Calendar.current.isDateInToday(timestamp) {
            return "Today"
        }
        if Calendar.current.isDateInYesterday(timestamp) {
            return "Yesterday"
        }
        return Self.dayFormatter.string(from: timestamp)
    }

    var searchableText: String {
        [title, detail, kind.title, status.rawValue, source]
            .compactMap(\.self)
            .joined(separator: " ")
            .localizedLowercase
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

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()
}

enum PlannedActionKind: String, Codable, CaseIterable {
    case openApp = "open_app"
    case openURL = "open_url"
    case quitApp = "quit_app"
    case writeNote = "write_note"
    case typeText = "type_text"
    case pressKeys = "press_keys"
    case scroll = "scroll"
    case click = "click"
    case doubleClick = "double_click"
    case moveMouse = "move_mouse"
    case drag = "drag"
    case screenshot = "screenshot"
    case inspectAccessibilityTree = "inspect_accessibility_tree"
    case clickElement = "click_element"
    case setFocusedText = "set_focused_text"
    case selectMenuItem = "select_menu_item"
    case browserBack = "browser_back"
    case browserForward = "browser_forward"
    case newTab = "new_tab"
    case closeTab = "close_tab"
    case switchTab = "switch_tab"
    case findTab = "find_tab"
    case runBrowserTask = "run_browser_task"
    case runVisualComputerTask = "run_visual_computer_task"
    case speak
    case unsupported
}

struct PlannedAction: Codable, Equatable {
    var action: PlannedActionKind
    var appName: String?
    var url: String?
    var text: String?
    var keys: [String]?
    var direction: String?
    var amount: Double?
    var x: Double?
    var y: Double?
    var endX: Double?
    var endY: Double?
    var button: String?
    var elementLabel: String?
    var role: String?
    var menuPath: String?
    var scope: String?
    var tabQuery: String?
    var tabIndex: Int?
    var maxSteps: Int?
    var browserBackend: String?
    var browserProfileMode: String?
    var browserProfile: String?
    var spokenText: String
    var risk: String
    var rationale: String

    static let schemaRequiredFields = [
        "action", "appName", "url", "text", "keys", "direction", "amount",
        "x", "y", "endX", "endY", "button", "elementLabel", "role",
        "menuPath", "scope", "tabQuery", "tabIndex", "maxSteps",
        "browserBackend", "browserProfileMode", "browserProfile",
        "spokenText", "risk", "rationale"
    ]

    static var jsonSchema: [String: Any] {
        [
            "type": "object",
            "additionalProperties": false,
            "properties": [
                "action": [
                    "type": "string",
                    "enum": PlannedActionKind.allCases.map(\.rawValue)
                ],
                "appName": [
                    "type": ["string", "null"],
                    "description": "Human macOS app name such as Calculator, Notes, Google Chrome, Safari, Finder, Mail, TextEdit, or any installed app."
                ],
                "url": [
                    "type": ["string", "null"],
                    "description": "URL for open_url or new_tab."
                ],
                "text": [
                    "type": ["string", "null"],
                    "description": "Text to type, set, write into Notes, speak, or use as the visual computer task goal."
                ],
                "keys": [
                    "type": ["array", "null"],
                    "items": ["type": "string"],
                    "description": "Keyboard chord or key list, such as ['cmd','l'] or ['escape']."
                ],
                "direction": [
                    "type": ["string", "null"],
                    "enum": ["up", "down", "left", "right", NSNull()],
                    "description": "Scroll direction."
                ],
                "amount": [
                    "type": ["number", "null"],
                    "description": "Scroll, movement, or action amount. Defaults to a medium amount."
                ],
                "x": [
                    "type": ["number", "null"],
                    "description": "Global screen x coordinate for mouse actions."
                ],
                "y": [
                    "type": ["number", "null"],
                    "description": "Global screen y coordinate for mouse actions."
                ],
                "endX": [
                    "type": ["number", "null"],
                    "description": "Global destination x coordinate for drag."
                ],
                "endY": [
                    "type": ["number", "null"],
                    "description": "Global destination y coordinate for drag."
                ],
                "button": [
                    "type": ["string", "null"],
                    "enum": ["left", "right", "middle", NSNull()]
                ],
                "elementLabel": [
                    "type": ["string", "null"],
                    "description": "Visible label/title/value of an accessibility element to act on."
                ],
                "role": [
                    "type": ["string", "null"],
                    "description": "Optional accessibility role filter, such as button, checkbox, text field, menu item."
                ],
                "menuPath": [
                    "type": ["string", "null"],
                    "description": "Menu path like File > New Window."
                ],
                "scope": [
                    "type": ["string", "null"],
                    "enum": ["screen", "active_window", "focused_app", NSNull()],
                    "description": "Observation scope for screenshots or accessibility inspection."
                ],
                "tabQuery": [
                    "type": ["string", "null"],
                    "description": "Browser tab title or URL search text."
                ],
                "tabIndex": [
                    "type": ["integer", "null"],
                    "description": "One-based tab index for switch_tab."
                ],
                "maxSteps": [
                    "type": ["integer", "null"],
                    "description": "Maximum visual computer-use loop turns."
                ],
                "browserBackend": [
                    "type": ["string", "null"],
                    "enum": ["live_chrome", "managed", NSNull()],
                    "description": "Use live_chrome for browser tasks in the user's running Chrome through the companion extension. Use managed only for the isolated Playwright browser fallback."
                ],
                "browserProfileMode": [
                    "type": ["string", "null"],
                    "enum": ["managed", "existing_chrome", NSNull()],
                    "description": "Compatibility field. Use existing_chrome with live_chrome and managed with managed."
                ],
                "browserProfile": [
                    "type": ["string", "null"],
                    "description": "Optional Chrome profile directory or display name, such as Default, Profile 3, or a Chrome profile name."
                ],
                "spokenText": [
                    "type": "string"
                ],
                "risk": [
                    "type": "string",
                    "enum": ["safe", "confirm", "blocked"]
                ],
                "rationale": [
                    "type": "string"
                ]
            ],
            "required": schemaRequiredFields
        ]
    }

    static func unsupported(_ message: String, rationale: String = "The request is outside the native prototype action surface.") -> PlannedAction {
        PlannedAction(
            action: .unsupported,
            appName: nil,
            url: nil,
            text: nil,
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
            browserBackend: nil,
            browserProfileMode: nil,
            browserProfile: nil,
            spokenText: message,
            risk: "blocked",
            rationale: rationale
        )
    }

    static func make(
        action: PlannedActionKind,
        appName: String? = nil,
        url: String? = nil,
        text: String? = nil,
        keys: [String]? = nil,
        direction: String? = nil,
        amount: Double? = nil,
        x: Double? = nil,
        y: Double? = nil,
        endX: Double? = nil,
        endY: Double? = nil,
        button: String? = nil,
        elementLabel: String? = nil,
        role: String? = nil,
        menuPath: String? = nil,
        scope: String? = nil,
        tabQuery: String? = nil,
        tabIndex: Int? = nil,
        maxSteps: Int? = nil,
        browserBackend: String? = nil,
        browserProfileMode: String? = nil,
        browserProfile: String? = nil,
        spokenText: String,
        risk: String,
        rationale: String
    ) -> PlannedAction {
        PlannedAction(
            action: action,
            appName: appName,
            url: url,
            text: text,
            keys: keys,
            direction: direction,
            amount: amount,
            x: x,
            y: y,
            endX: endX,
            endY: endY,
            button: button,
            elementLabel: elementLabel,
            role: role,
            menuPath: menuPath,
            scope: scope,
            tabQuery: tabQuery,
            tabIndex: tabIndex,
            maxSteps: maxSteps,
            browserBackend: browserBackend,
            browserProfileMode: browserProfileMode,
            browserProfile: browserProfile,
            spokenText: spokenText,
            risk: risk,
            rationale: rationale
        )
    }
}
