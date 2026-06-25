import Foundation
import Observation

enum PlannerError: LocalizedError {
    case missingAPIKey
    case badResponse(Int, String)
    case missingOutput

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            "Add a .openai file at the project root or set OPENAI_API_KEY."
        case let .badResponse(status, body):
            "OpenAI returned HTTP \(status): \(body)"
        case .missingOutput:
            "OpenAI did not return a structured action."
        }
    }
}

@Observable
@MainActor
final class OpenAIPlannerService {
    var isPlanning = false
    var lastPlan: PlannedAction?
    var lastError: String?

    private let endpoint = URL(string: "https://api.openai.com/v1/responses")!

    func plan(command: String, context: ActiveWorkspaceContext? = nil) async -> PlannedAction {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .unsupported("Tell me what you want me to do.", rationale: "Empty command.")
        }

        if let deterministicPlan = deterministicPlan(for: trimmed, context: context) {
            lastError = nil
            lastPlan = deterministicPlan
            return deterministicPlan
        }

        isPlanning = true
        lastError = nil
        defer { isPlanning = false }

        do {
            let action = try await requestPlan(command: trimmed, context: context)
            lastPlan = action
            return action
        } catch {
            let message = error.localizedDescription
            lastError = message
            let action = PlannedAction.unsupported(message, rationale: "Planner request failed.")
            lastPlan = action
            return action
        }
    }

    private func requestPlan(command: String, context: ActiveWorkspaceContext?) async throws -> PlannedAction {
        guard let key = OpenAIConfiguration.apiKey() else {
            throw PlannerError.missingAPIKey
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(OpenAIConfiguration.safetyIdentifier(), forHTTPHeaderField: "OpenAI-Safety-Identifier")
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody(command: command, context: context))

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw PlannerError.badResponse(status, String(data: data, encoding: .utf8) ?? "")
        }

        guard let output = outputText(from: data), let outputData = output.data(using: .utf8) else {
            throw PlannerError.missingOutput
        }

        return try JSONDecoder().decode(PlannedAction.self, from: outputData)
    }

    private func requestBody(command: String, context: ActiveWorkspaceContext?) -> [String: Any] {
        let userText: String
        if let context {
            userText = """
            \(context.promptSummary)

            User request:
            \(command)
            """
        } else {
            userText = command
        }

        return [
            "model": ProcessInfo.processInfo.environment["OPENAI_PLANNER_MODEL"] ?? "gpt-4o-mini",
            "store": false,
            "input": [
                [
                    "role": "system",
                    "content": [
                        [
                            "type": "input_text",
                            "text": plannerInstructions
                        ]
                    ]
                ],
                [
                    "role": "user",
                    "content": [
                        [
                            "type": "input_text",
                            "text": userText
                        ]
                    ]
                ]
            ],
            "text": [
                "format": [
                    "type": "json_schema",
                    "name": "computer_control_action",
                    "strict": true,
                    "schema": actionSchema
                ]
            ]
        ]
    }

    private var plannerInstructions: String {
        """
        Convert the user's free-form computer-control request into exactly one JSON action.
        Supported actions:
        - open_app: open or focus a macOS app by human app name.
        - open_url: open an http or https URL.
        - quit_app: quit a macOS app by human app name.
        - write_note: open Notes, create a new note, and type the requested note text.
        - type_text: type literal text into the currently focused app.
        - press_keys: press a small keyboard shortcut or key sequence.
        - scroll: scroll the focused UI or a global screen coordinate.
        - click, double_click, move_mouse, drag: use only when the user gives coordinates or a visual computer-use loop has provided coordinates.
        - screenshot: capture the screen or active window for observation.
        - inspect_accessibility_tree: summarize focused app or active window UI controls.
        - click_element: press an accessibility element by visible label/title/value.
        - set_focused_text: set the focused text field value, falling back to typing if needed.
        - select_menu_item: select an app menu item using a menu path like File > New Window.
        - browser_back, browser_forward, new_tab, close_tab, switch_tab, find_tab: deterministic browser/tab controls.
        - run_browser_task: use for Gmail, email drafts, clicking browser page elements, filling web forms, and browser workflows that benefit from DOM/accessibility selectors.
        - run_visual_computer_task: use for open-ended "look at my screen and operate it" tasks that need screenshots and multiple UI actions.
        - speak: answer verbally without changing the computer.
        - unsupported: use when the request asks for unavailable or unsafe capabilities such as bypassing authentication, CAPTCHAs, purchases, or sending/submitting sensitive data without confirmation.
        Do not claim an action already happened. Return the next native action only.
        Use the current active workspace context when provided. For ambiguous follow-ups like "this", "here", "that page", "continue", "look up this address", "click that", or "fill this", prefer continuing in the active workspace. Do not open a new browser tab or app unless the user explicitly asks for a new one or the current workspace is clearly irrelevant.
        For run_browser_task, use browserBackend "live_chrome" for Gmail, web pages, page clicks, and the user's running/logged-in Chrome. Use browserBackend "managed" only when the user explicitly asks for an isolated managed browser fallback.
        Keep browserProfileMode for compatibility: set it to "existing_chrome" when browserBackend is "live_chrome", and "managed" when browserBackend is "managed".
        Prefer app/browser/Accessibility actions before raw coordinate actions. Use risk "safe" for observation/opening/navigation, "confirm" for typing, clicking, quitting, forms, or messages, and "blocked" for unsupported.
        """
    }

    private var actionSchema: [String: Any] {
        PlannedAction.jsonSchema
    }

    private func deterministicPlan(for command: String, context: ActiveWorkspaceContext?) -> PlannedAction? {
        let normalized = normalizedCommand(command)

        if shouldContinueInActiveBrowser(normalized, context: context) {
            return browserTaskPlan(
                command,
                useInitialURL: false,
                rationale: "The request is an ambiguous follow-up, so it should continue in the active Chrome tab."
            )
        }

        if isBrowserAutomationRequest(normalized) {
            return browserTaskPlan(command, rationale: "Browser page interaction should use Live Chrome when the extension is connected.")
        }

        if isNotesWriteRequest(normalized) {
            return notesPlan(command, rationale: "Notes writing should use the native Notes demo path.")
        }

        if containsAny(normalized, ["screenshot", "screen shot", "capture my screen", "take a picture of my screen"]) {
            if containsAny(normalized, ["figure out", "where to click", "click", "draft", "email", "fill", "send", "reply", "use it", "look at"]) {
                return visualComputerPlan(command, rationale: "Screen capture plus UI reasoning needs the visual computer-use loop.")
            }

            return .make(
                action: .screenshot,
                scope: containsAny(normalized, ["window", "windows", "active"]) ? "active_window" : "screen",
                spokenText: "I'll take a screenshot.",
                risk: "safe",
                rationale: "The command is a direct screen capture request."
            )
        }

        if containsAny(normalized, ["look at my screen", "look at the screen", "read my screen", "what is on my screen", "observe my screen", "see my screen", "where to click", "figure out where", "use my screen"]) {
            return visualComputerPlan(command, rationale: "The command requires observing the current screen before acting.")
        }

        if containsAny(normalized, ["scroll down", "scroll up", "scroll left", "scroll right"]) {
            let direction: String
            if normalized.contains("scroll up") {
                direction = "up"
            } else if normalized.contains("scroll left") {
                direction = "left"
            } else if normalized.contains("scroll right") {
                direction = "right"
            } else {
                direction = "down"
            }

            return .make(
                action: .scroll,
                direction: direction,
                amount: 520,
                spokenText: "I'll scroll \(direction).",
                risk: "confirm",
                rationale: "The command is a direct scroll request."
            )
        }

        if containsAny(normalized, ["browser back", "go back", "back in chrome", "back in safari"]) {
            return .make(
                action: .browserBack,
                appName: browserName(in: normalized),
                spokenText: "I'll go back.",
                risk: "safe",
                rationale: "The command is a deterministic browser navigation request."
            )
        }

        if containsAny(normalized, ["browser forward", "go forward", "forward in chrome", "forward in safari"]) {
            return .make(
                action: .browserForward,
                appName: browserName(in: normalized),
                spokenText: "I'll go forward.",
                risk: "safe",
                rationale: "The command is a deterministic browser navigation request."
            )
        }

        if containsAny(normalized, ["new tab", "open a tab", "open new tab"]) {
            return .make(
                action: .newTab,
                appName: browserName(in: normalized),
                spokenText: "I'll open a new tab.",
                risk: "safe",
                rationale: "The command is a deterministic browser tab request."
            )
        }

        if containsAny(normalized, ["close tab", "close this tab", "close current tab"]) {
            return .make(
                action: .closeTab,
                appName: browserName(in: normalized),
                spokenText: "I'll close the current tab.",
                risk: "confirm",
                rationale: "The command is a deterministic browser tab request."
            )
        }

        if containsAny(normalized, ["inspect accessibility", "accessibility tree", "inspect ui", "list controls"]) {
            return .make(
                action: .inspectAccessibilityTree,
                scope: "active_window",
                spokenText: "I'll inspect the current interface.",
                risk: "safe",
                rationale: "The command asks for the accessibility tree."
            )
        }

        return nil
    }

    private func visualComputerPlan(_ command: String, rationale: String) -> PlannedAction {
        .make(
            action: .runVisualComputerTask,
            text: command,
            scope: "screen",
            maxSteps: 10,
            spokenText: "I'll look at the screen and work through it.",
            risk: "confirm",
            rationale: rationale
        )
    }

    private func browserTaskPlan(_ command: String, useInitialURL: Bool = true, rationale: String) -> PlannedAction {
        let normalized = normalizedCommand(command)
        let backend = browserBackend(for: normalized)
        let profileMode = backend == "live_chrome" ? "existing_chrome" : "managed"
        return .make(
            action: .runBrowserTask,
            url: useInitialURL ? browserInitialURL(for: normalized) : nil,
            text: command,
            maxSteps: 12,
            browserBackend: backend,
            browserProfileMode: profileMode,
            browserProfile: chromeProfileHint(in: command),
            spokenText: backend == "live_chrome" ? "I'll use live Chrome for that." : "I'll use the managed browser for that.",
            risk: "confirm",
            rationale: rationale
        )
    }

    private func notesPlan(_ command: String, rationale: String) -> PlannedAction {
        .make(
            action: .writeNote,
            appName: "Notes",
            text: noteText(from: command),
            spokenText: "I'll create that note in Notes.",
            risk: "confirm",
            rationale: rationale
        )
    }

    private func isNotesWriteRequest(_ normalized: String) -> Bool {
        containsAny(normalized, ["notes", "note"]) &&
            containsAny(normalized, ["write", "create", "draft", "checklist", "list"])
    }

    private func isBrowserAutomationRequest(_ normalized: String) -> Bool {
        containsAny(normalized, [
            "gmail",
            "google mail",
            "draft an email",
            "write an email",
            "compose an email",
            "draft email",
            "compose email",
            "click compose",
            "click the compose",
            "click button",
            "click link",
            "fill the form",
            "fill form",
            "browser task",
            "use the browser",
            "web page",
            "website",
            "existing chrome",
            "my chrome",
            "regular chrome",
            "current chrome",
            "logged in chrome",
            "personal chrome",
            "chrome profile",
            "existing profile",
            "current profile",
            "logged in profile"
        ])
    }

    private func shouldContinueInActiveBrowser(_ normalized: String, context: ActiveWorkspaceContext?) -> Bool {
        guard context?.isBrowser == true else { return false }

        if containsAny(normalized, [
            "new tab",
            "open a new tab",
            "open new tab",
            "new window",
            "fresh tab",
            "start fresh",
            "go to gmail",
            "open gmail",
            "go to google",
            "open google"
        ]) {
            return false
        }

        return containsAny(normalized, [
            "this address",
            "that address",
            "the address",
            "this listing",
            "that listing",
            "this property",
            "that property",
            "this page",
            "that page",
            "current page",
            "current tab",
            "on this page",
            "on the page",
            "look up this",
            "look this up",
            "look up the address",
            "search this",
            "check this",
            "continue",
            "keep going",
            "use this",
            "use the current",
            "click that",
            "click this",
            "fill this",
            "fill that",
            "scroll this",
            "read this"
        ])
    }

    private func browserInitialURL(for normalized: String) -> String? {
        if containsAny(normalized, ["gmail", "google mail", "email", "compose"]) {
            return "https://mail.google.com/mail/u/0/#inbox"
        }
        return nil
    }

    private func noteText(from command: String) -> String {
        let normalized = normalizedCommand(command)
        if containsAny(normalized, ["demo", "checklist", "what we just demoed", "what just demoed"]) {
            return """
            Computer Control Demo

            - Voice command received
            - Live Chrome can draft in Gmail
            - Native Notes can be controlled
            - Stop cancels speech or actions
            - Activity history records every step
            """
        }

        let markers = ["saying", "that says", "with text", "write"]
        for marker in markers {
            if let range = command.range(of: marker, options: [.caseInsensitive]) {
                let text = command[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    return text
                }
            }
        }

        return command
    }

    private func browserProfileMode(for normalized: String) -> String {
        browserBackend(for: normalized) == "live_chrome" ? "existing_chrome" : "managed"
    }

    private func browserBackend(for normalized: String) -> String {
        if containsAny(normalized, [
            "managed browser",
            "managed chromium",
            "isolated browser",
            "playwright browser"
        ]) {
            return "managed"
        }

        if containsAny(normalized, [
            "existing chrome",
            "my chrome",
            "regular chrome",
            "current chrome",
            "logged in chrome",
            "personal chrome",
            "real chrome",
            "chrome profile",
            "existing profile",
            "current profile",
            "logged in profile",
            "my profile"
        ]) {
            return "live_chrome"
        }
        return "live_chrome"
    }

    private func chromeProfileHint(in command: String) -> String? {
        let profilePattern = #"(?:profile\s*)(\d+)"#
        guard let regex = try? NSRegularExpression(pattern: profilePattern, options: [.caseInsensitive]) else {
            return nil
        }
        let range = NSRange(command.startIndex..<command.endIndex, in: command)
        guard let match = regex.firstMatch(in: command, range: range),
              match.numberOfRanges > 1,
              let numberRange = Range(match.range(at: 1), in: command) else {
            if command.localizedCaseInsensitiveContains("default profile") {
                return "Default"
            }
            return nil
        }
        return "Profile \(command[numberRange])"
    }

    private func browserName(in normalizedCommand: String) -> String? {
        if normalizedCommand.contains("safari") {
            return "Safari"
        }
        if normalizedCommand.contains("chrome") || normalizedCommand.contains("browser") {
            return "Google Chrome"
        }
        return nil
    }

    private func normalizedCommand(_ command: String) -> String {
        let lowercased = command.localizedLowercase
        let characters = lowercased.map { character in
            character.isLetter || character.isNumber ? character : " "
        }
        return String(characters)
            .split(separator: " ")
            .joined(separator: " ")
    }

    private func containsAny(_ command: String, _ phrases: [String]) -> Bool {
        phrases.contains { command.contains($0) }
    }

    private func outputText(from data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let root = object as? [String: Any] else {
            return nil
        }

        if let outputText = root["output_text"] as? String {
            return outputText
        }

        return firstOutputText(in: root["output"])
    }

    private func firstOutputText(in value: Any?) -> String? {
        if let string = value as? String {
            return string
        }

        if let array = value as? [Any] {
            for item in array {
                if let found = firstOutputText(in: item) {
                    return found
                }
            }
        }

        if let dictionary = value as? [String: Any] {
            if let type = dictionary["type"] as? String,
               (type == "output_text" || type == "text"),
               let text = dictionary["text"] as? String {
                return text
            }

            for key in ["content", "output", "message"] {
                if let found = firstOutputText(in: dictionary[key]) {
                    return found
                }
            }
        }

        return nil
    }
}
