import AppKit
import ApplicationServices
import Foundation
import Observation
@preconcurrency import ScreenCaptureKit

@Observable
@MainActor
final class AppActionService {
    var lastResult: ActionResult?
    var isExecutingAction = false
    var currentActionDescription = "Idle"

    private var cancelRequested = false
    private var currentProcess: Process?
    private let browserAutomation = BrowserAutomationService()
    private let chromeLiveAutomation: ChromeLiveAutomationService
    private let screenshotDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("ComputerControl", isDirectory: true)

    init(chromeLiveAutomation: ChromeLiveAutomationService = ChromeLiveAutomationService()) {
        self.chromeLiveAutomation = chromeLiveAutomation
    }

    func execute(plan: PlannedAction, safetyMode: SafetyMode = .powerUser) async -> ActionResult {
        cancelRequested = false
        isExecutingAction = true
        currentActionDescription = plan.action.rawValue
        defer {
            isExecutingAction = false
            currentActionDescription = "Idle"
            currentProcess = nil
        }

        let result: ActionResult

        if let blockedReason = ActionSafetyPolicy.blockedReason(for: plan, safetyMode: safetyMode) {
            result = blocked("That needs explicit confirmation first.", detail: blockedReason)
        } else {
            switch plan.action {
            case .openApp:
                result = await openApp(named: plan.appName)
            case .openURL:
                result = await openURL(plan.url, appName: plan.appName)
            case .quitApp:
                result = await quitApp(named: plan.appName)
            case .writeNote:
                result = await writeNote(plan.text)
            case .typeText:
                result = typeText(plan.text)
            case .pressKeys:
                result = pressKeys(plan.keys)
            case .scroll:
                result = scroll(direction: plan.direction, amount: plan.amount, x: plan.x, y: plan.y, keys: plan.keys)
            case .click:
                result = clickMouse(x: plan.x, y: plan.y, button: plan.button, clickCount: 1, keys: plan.keys)
            case .doubleClick:
                result = clickMouse(x: plan.x, y: plan.y, button: plan.button, clickCount: 2, keys: plan.keys)
            case .moveMouse:
                result = moveMouse(x: plan.x, y: plan.y, keys: plan.keys)
            case .drag:
                result = dragMouse(startX: plan.x, startY: plan.y, endX: plan.endX, endY: plan.endY, keys: plan.keys)
            case .screenshot:
                result = await captureScreenshot(scope: plan.scope)
            case .inspectAccessibilityTree:
                result = await inspectAccessibilityTree(appName: plan.appName, scope: plan.scope)
            case .clickElement:
                result = await clickElement(label: plan.elementLabel ?? plan.text, role: plan.role, appName: plan.appName)
            case .setFocusedText:
                result = setFocusedText(plan.text)
            case .selectMenuItem:
                result = await selectMenuItem(appName: plan.appName, menuPath: plan.menuPath ?? plan.text)
            case .browserBack:
                result = await browserShortcut(appName: plan.appName, keys: ["cmd", "["], spoken: "Went back.", detail: "Pressed Command-[ in the browser.")
            case .browserForward:
                result = await browserShortcut(appName: plan.appName, keys: ["cmd", "]"], spoken: "Went forward.", detail: "Pressed Command-] in the browser.")
            case .newTab:
                result = await newBrowserTab(appName: plan.appName, url: plan.url)
            case .closeTab:
                result = await browserShortcut(appName: plan.appName, keys: ["cmd", "w"], spoken: "Closed the current tab.", detail: "Pressed Command-W in the browser.")
            case .switchTab:
                result = await switchBrowserTab(appName: plan.appName, index: plan.tabIndex, direction: plan.direction)
            case .findTab:
                result = await findBrowserTab(appName: plan.appName, query: plan.tabQuery ?? plan.text)
            case .runBrowserTask:
                result = await runBrowserTask(
                    goal: plan.text ?? plan.rationale,
                    url: plan.url,
                    maxSteps: plan.maxSteps,
                    browserBackend: plan.browserBackend,
                    browserProfileMode: plan.browserProfileMode,
                    browserProfile: plan.browserProfile
                )
            case .runVisualComputerTask:
                result = await runVisualComputerTask(goal: plan.text ?? plan.rationale, maxSteps: plan.maxSteps)
            case .speak:
                result = ActionResult(
                    succeeded: true,
                    spokenText: plan.spokenText,
                    detail: plan.rationale
                )
            case .unsupported:
                result = ActionResult(
                    succeeded: false,
                    spokenText: plan.spokenText,
                    detail: plan.rationale
                )
            }
        }

        lastResult = result
        return result
    }

    func cancelCurrentAction(reason: String) {
        guard isExecutingAction else { return }

        cancelRequested = true
        currentActionDescription = "Cancelling"
        currentProcess?.terminate()
        browserAutomation.cancelCurrentTask()
        chromeLiveAutomation.cancelCurrentTask()
        lastResult = ActionResult(
            succeeded: false,
            spokenText: "Cancelled.",
            detail: reason
        )
    }

    private func openApp(named appName: String?) async -> ActionResult {
        guard let appName = nonEmpty(appName) else {
            return blocked("I need an app name to open.", detail: "Planner omitted appName.")
        }

        do {
            try await run("/usr/bin/open", ["-a", appName])
            return ActionResult(
                succeeded: true,
                spokenText: "Opened \(appName).",
                detail: "Opened app with /usr/bin/open -a \(appName)."
            )
        } catch {
            if cancelRequested {
                return cancelledResult()
            }
            return blocked("I could not open \(appName).", detail: error.localizedDescription)
        }
    }

    private func openURL(_ rawURL: String?, appName: String?) async -> ActionResult {
        guard let rawURL = nonEmpty(rawURL),
              let url = normalizedOpenURL(rawURL) else {
            return blocked("I need a valid URL.", detail: "Supported URL schemes: http, https, and chrome.")
        }

        let displayName = displayName(for: url)

        if let appName = nonEmpty(appName) {
            do {
                try await run("/usr/bin/open", ["-a", appName, url.absoluteString])
                return ActionResult(
                    succeeded: true,
                    spokenText: "Opened \(displayName) in \(appName).",
                    detail: "Opened URL \(url.absoluteString) with /usr/bin/open -a \(appName)."
                )
            } catch {
                if cancelRequested {
                    return cancelledResult()
                }
                return blocked("I could not open \(displayName) in \(appName).", detail: error.localizedDescription)
            }
        }

        NSWorkspace.shared.open(url)
        return ActionResult(
            succeeded: true,
            spokenText: "Opened \(displayName).",
            detail: "Opened URL \(url.absoluteString)."
        )
    }

    private func quitApp(named appName: String?) async -> ActionResult {
        guard let appName = nonEmpty(appName) else {
            return blocked("I need an app name to quit.", detail: "Planner omitted appName.")
        }

        do {
            try await runAppleScript("tell application \"\(appleScriptEscaped(appName))\" to if it is running then quit")
            return ActionResult(
                succeeded: true,
                spokenText: "Closed \(appName).",
                detail: "Asked \(appName) to quit through Apple Events."
            )
        } catch {
            if cancelRequested {
                return cancelledResult()
            }
            return blocked("I could not close \(appName).", detail: error.localizedDescription)
        }
    }

    private func writeNote(_ text: String?) async -> ActionResult {
        if let blocked = requireAccessibility() {
            return blocked
        }

        guard let text = nonEmpty(text) else {
            return blocked("I need note text to write.", detail: "Planner omitted text for write_note.")
        }

        do {
            try await run("/usr/bin/open", ["-a", "Notes"])
            try await Task.sleep(for: .milliseconds(900))
            _ = pressKeyChord(["cmd", "n"])
            try await Task.sleep(for: .milliseconds(250))
            let typed = typeText(text)
            guard typed.succeeded else {
                return typed
            }
            return ActionResult(
                succeeded: true,
                spokenText: "Created the note.",
                detail: "Opened Notes, created a new note, and typed \(text.count) characters."
            )
        } catch {
            if cancelRequested {
                return cancelledResult()
            }
            return blocked("I could not write the note.", detail: error.localizedDescription)
        }
    }

    private func typeText(_ text: String?) -> ActionResult {
        if let blocked = requireAccessibility() {
            return blocked
        }

        guard let text = nonEmpty(text) else {
            return blocked("I need text to type.", detail: "Planner omitted text.")
        }

        let source = CGEventSource(stateID: .combinedSessionState)
        let utf16 = Array(text.utf16)
        utf16.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }

            let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true)
            keyDown?.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: base)
            keyDown?.post(tap: .cghidEventTap)

            let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
            keyUp?.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: base)
            keyUp?.post(tap: .cghidEventTap)
        }

        return ActionResult(
            succeeded: true,
            spokenText: "Typed the text.",
            detail: "Typed \(text.count) characters into the focused app."
        )
    }

    private func pressKeys(_ keys: [String]?) -> ActionResult {
        if let blocked = requireAccessibility() {
            return blocked
        }

        guard let keys, !keys.isEmpty else {
            return blocked("I need keys to press.", detail: "Planner omitted keys.")
        }

        let normalized = keys.map(normalizeKeyName)
        let nonModifierKeys = normalized.filter { !modifierNames.contains($0) }

        if nonModifierKeys.count <= 1 {
            return pressKeyChord(normalized)
        }

        for key in normalized {
            let result = pressKeyChord([key])
            if !result.succeeded {
                return result
            }
        }

        return ActionResult(
            succeeded: true,
            spokenText: "Pressed the key sequence.",
            detail: "Pressed key sequence: \(keys.joined(separator: ", "))."
        )
    }

    private func pressKeyChord(_ keys: [String]) -> ActionResult {
        var flags: CGEventFlags = []
        var keyName: String?

        for key in keys {
            switch key {
            case "cmd", "command", "meta":
                flags.insert(.maskCommand)
            case "shift":
                flags.insert(.maskShift)
            case "option", "alt":
                flags.insert(.maskAlternate)
            case "control", "ctrl":
                flags.insert(.maskControl)
            default:
                keyName = key
            }
        }

        guard let keyName, let keyCode = keyCodes[keyName] else {
            return blocked("I do not know that key yet.", detail: "Unsupported key sequence: \(keys.joined(separator: " + ")).")
        }

        let source = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
        down?.flags = flags
        down?.post(tap: .cghidEventTap)

        let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        up?.flags = flags
        up?.post(tap: .cghidEventTap)

        return ActionResult(
            succeeded: true,
            spokenText: "Pressed \(keys.joined(separator: " ")).",
            detail: "Pressed key sequence: \(keys.joined(separator: " + "))."
        )
    }

    private func scroll(direction: String?, amount: Double?, x: Double?, y: Double?, keys: [String]? = nil) -> ActionResult {
        let distance = max(40, min(amount ?? 420, 2_500))
        let normalized = direction?.lowercased() ?? "down"
        let scrollX: Double
        let scrollY: Double

        switch normalized {
        case "up":
            scrollX = 0
            scrollY = distance
        case "left":
            scrollX = distance
            scrollY = 0
        case "right":
            scrollX = -distance
            scrollY = 0
        default:
            scrollX = 0
            scrollY = -distance
        }

        return scrollByDelta(scrollX: scrollX, scrollY: scrollY, x: x, y: y, keys: keys)
    }

    private func scrollByDelta(scrollX: Double, scrollY: Double, x: Double?, y: Double?, keys: [String]? = nil) -> ActionResult {
        if let blocked = requireAccessibility() {
            return blocked
        }

        if let blocked = performWithHeldKeys(keys, action: {
            if let point = pointFrom(x: x, y: y) {
                postMouseMove(to: point)
            }

            let source = CGEventSource(stateID: .combinedSessionState)
            let event = CGEvent(
                scrollWheelEvent2Source: source,
                units: .pixel,
                wheelCount: 2,
                wheel1: Int32(scrollY),
                wheel2: Int32(scrollX),
                wheel3: 0
            )
            event?.post(tap: .cghidEventTap)
        }) {
            return blocked
        }

        return ActionResult(
            succeeded: true,
            spokenText: "Scrolled.",
            detail: "Posted scroll delta x=\(Int(scrollX)), y=\(Int(scrollY))."
        )
    }

    private func moveMouse(x: Double?, y: Double?, keys: [String]? = nil) -> ActionResult {
        if let blocked = requireAccessibility() {
            return blocked
        }

        guard let point = pointFrom(x: x, y: y) else {
            return blocked("I need screen coordinates to move the mouse.", detail: "Planner omitted x or y.")
        }

        if let blocked = performWithHeldKeys(keys, action: {
            postMouseMove(to: point)
        }) {
            return blocked
        }

        return ActionResult(
            succeeded: true,
            spokenText: "Moved the pointer.",
            detail: "Moved pointer to \(Int(point.x)), \(Int(point.y))."
        )
    }

    private func clickMouse(x: Double?, y: Double?, button: String?, clickCount: Int, keys: [String]? = nil) -> ActionResult {
        if let blocked = requireAccessibility() {
            return blocked
        }

        guard let point = pointFrom(x: x, y: y) else {
            return blocked("I need screen coordinates to click.", detail: "Planner omitted x or y.")
        }

        let mouseButton = mouseButton(named: button)
        if let blocked = performWithHeldKeys(keys, action: {
            postMouseClick(at: point, button: mouseButton, clickCount: clickCount)
        }) {
            return blocked
        }

        return ActionResult(
            succeeded: true,
            spokenText: clickCount > 1 ? "Double clicked." : "Clicked.",
            detail: "\(clickCount > 1 ? "Double clicked" : "Clicked") \(mouseButton.name) at \(Int(point.x)), \(Int(point.y))."
        )
    }

    private func dragMouse(startX: Double?, startY: Double?, endX: Double?, endY: Double?, keys: [String]? = nil) -> ActionResult {
        if let blocked = requireAccessibility() {
            return blocked
        }

        guard let start = pointFrom(x: startX, y: startY),
              let end = pointFrom(x: endX, y: endY) else {
            return blocked("I need start and end coordinates to drag.", detail: "Planner omitted x, y, endX, or endY.")
        }

        if let blocked = performWithHeldKeys(keys, action: {
            postMouseDrag(from: start, to: end)
        }) {
            return blocked
        }
        return ActionResult(
            succeeded: true,
            spokenText: "Dragged.",
            detail: "Dragged from \(Int(start.x)), \(Int(start.y)) to \(Int(end.x)), \(Int(end.y))."
        )
    }

    private func captureScreenshot(scope: String?) async -> ActionResult {
        guard CGPreflightScreenCaptureAccess() else {
            return blocked(
                "Screen Recording permission is required before I can see the screen.",
                detail: "CGPreflightScreenCaptureAccess returned false."
            )
        }

        do {
            let capture = try await captureScreenshotData(scope: scope)
            return ActionResult(
                succeeded: true,
                spokenText: "Captured a screenshot.",
                detail: "Saved \(capture.width)x\(capture.height) screenshot to \(capture.path.path)."
            )
        } catch {
            return blocked("I could not capture the screen.", detail: error.localizedDescription)
        }
    }

    private func inspectAccessibilityTree(appName: String?, scope: String?) async -> ActionResult {
        if let blocked = requireAccessibility() {
            return blocked
        }

        do {
            if let appName = nonEmpty(appName) {
                try await focusAppIfProvided(appName)
            }

            guard let root = accessibilityRoot(appName: appName, scope: scope) else {
                return blocked("I could not find an accessibility root to inspect.", detail: "No focused app/window was available.")
            }

            var lines: [String] = []
            collectAccessibilitySummary(root, depth: 0, maxDepth: 5, maxElements: 120, lines: &lines)
            let summary = lines.isEmpty ? "No accessibility elements were exposed." : lines.joined(separator: "\n")
            return ActionResult(
                succeeded: true,
                spokenText: "I inspected the current interface.",
                detail: summary
            )
        } catch {
            return blocked("I could not inspect the interface.", detail: error.localizedDescription)
        }
    }

    private func clickElement(label: String?, role: String?, appName: String?) async -> ActionResult {
        if let blocked = requireAccessibility() {
            return blocked
        }

        guard let label = nonEmpty(label) else {
            return blocked("I need an element label to click.", detail: "Planner omitted elementLabel.")
        }

        do {
            if let appName = nonEmpty(appName) {
                try await focusAppIfProvided(appName)
            }

            guard let root = accessibilityRoot(appName: appName, scope: "active_window") ?? accessibilityRoot(appName: appName, scope: "focused_app") else {
                return blocked("I could not find the app UI.", detail: "No accessibility root was available.")
            }

            guard let match = findAccessibilityElement(root, label: label, role: role, maxDepth: 8, maxElements: 350) else {
                return blocked("I could not find \(label).", detail: "No accessibility element matched the requested label and role.")
            }

            if performPress(on: match.element) {
                return ActionResult(
                    succeeded: true,
                    spokenText: "Clicked \(label).",
                    detail: "Performed AXPress on \(match.summary)."
                )
            }

            guard let frame = accessibilityFrame(match.element) else {
                return blocked("I found \(label), but it is not directly clickable.", detail: "Element did not expose AXPress or a usable frame.")
            }

            let center = CGPoint(x: frame.midX, y: frame.midY)
            postMouseClick(at: center, button: .left, clickCount: 1)
            return ActionResult(
                succeeded: true,
                spokenText: "Clicked \(label).",
                detail: "Clicked center of \(match.summary) at \(Int(center.x)), \(Int(center.y))."
            )
        } catch {
            return blocked("I could not click \(label).", detail: error.localizedDescription)
        }
    }

    private func setFocusedText(_ text: String?) -> ActionResult {
        if let blocked = requireAccessibility() {
            return blocked
        }

        guard let text = nonEmpty(text) else {
            return blocked("I need text to enter.", detail: "Planner omitted text.")
        }

        let system = AXUIElementCreateSystemWide()
        guard let focusedValue = copyAXAttribute(system, kAXFocusedUIElementAttribute) else {
            return typeText(text)
        }
        let focused = focusedValue as! AXUIElement

        let error = AXUIElementSetAttributeValue(focused, kAXValueAttribute as CFString, text as CFTypeRef)
        if error == .success {
            return ActionResult(
                succeeded: true,
                spokenText: "Set the focused text.",
                detail: "Set AXValue on the focused element."
            )
        }

        return typeText(text)
    }

    private func selectMenuItem(appName: String?, menuPath: String?) async -> ActionResult {
        if let blocked = requireAccessibility() {
            return blocked
        }

        guard let menuPath = nonEmpty(menuPath) else {
            return blocked("I need a menu path.", detail: "Planner omitted menuPath.")
        }

        let targetApp = nonEmpty(appName) ?? NSWorkspace.shared.frontmostApplication?.localizedName
        guard let targetApp else {
            return blocked("I need an app for the menu command.", detail: "No appName or frontmost app was available.")
        }

        do {
            try await focusAppIfProvided(targetApp)
            let tokens = menuPath
                .components(separatedBy: ">")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            guard tokens.count >= 2 else {
                return blocked("Menu paths need at least a menu and item.", detail: "Use a path like File > New Window.")
            }

            let script = systemEventsMenuClickScript(appName: targetApp, tokens: tokens)
            try await runAppleScript(script)
            return ActionResult(
                succeeded: true,
                spokenText: "Selected \(tokens.last ?? menuPath).",
                detail: "Selected menu path \(menuPath) in \(targetApp)."
            )
        } catch {
            if cancelRequested {
                return cancelledResult()
            }
            return blocked("I could not select that menu item.", detail: error.localizedDescription)
        }
    }

    private func browserShortcut(appName: String?, keys: [String], spoken: String, detail: String) async -> ActionResult {
        do {
            try await focusAppIfProvided(browserAppName(from: appName))
        } catch {
            return blocked("I could not focus the browser.", detail: error.localizedDescription)
        }

        let result = pressKeys(keys)
        guard result.succeeded else { return result }
        return ActionResult(succeeded: true, spokenText: spoken, detail: detail)
    }

    private func newBrowserTab(appName: String?, url: String?) async -> ActionResult {
        if let url = nonEmpty(url) {
            return await openURL(url, appName: browserAppName(from: appName))
        }

        return await browserShortcut(
            appName: appName,
            keys: ["cmd", "t"],
            spoken: "Opened a new tab.",
            detail: "Pressed Command-T in the browser."
        )
    }

    private func switchBrowserTab(appName: String?, index: Int?, direction: String?) async -> ActionResult {
        do {
            try await focusAppIfProvided(browserAppName(from: appName))
        } catch {
            return blocked("I could not focus the browser.", detail: error.localizedDescription)
        }

        if let index, (1...9).contains(index) {
            let result = pressKeys(["cmd", "\(index)"])
            guard result.succeeded else { return result }
            return ActionResult(
                succeeded: true,
                spokenText: "Switched tabs.",
                detail: "Pressed Command-\(index) in the browser."
            )
        }

        let keys = direction == "left" || direction == "previous" ? ["control", "shift", "tab"] : ["control", "tab"]
        let result = pressKeys(keys)
        guard result.succeeded else { return result }
        return ActionResult(
            succeeded: true,
            spokenText: "Switched tabs.",
            detail: "Pressed \(keys.joined(separator: "-")) in the browser."
        )
    }

    private func findBrowserTab(appName: String?, query: String?) async -> ActionResult {
        guard let query = nonEmpty(query) else {
            return blocked("I need a tab title or URL to find.", detail: "Planner omitted tabQuery.")
        }

        let appName = browserAppName(from: appName)
        do {
            try await focusAppIfProvided(appName)
            let script: String
            if appName.localizedCaseInsensitiveContains("safari") {
                script = safariFindTabScript(query: query)
            } else {
                script = chromeFindTabScript(query: query)
            }

            let output = try await runReturningOutput("/usr/bin/osascript", ["-e", script])
            let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed != "__NOT_FOUND__" else {
                return blocked("I could not find that tab.", detail: "No browser tab matched \(query).")
            }

            return ActionResult(
                succeeded: true,
                spokenText: "Found that tab.",
                detail: "Activated tab: \(trimmed)."
            )
        } catch {
            if cancelRequested {
                return cancelledResult()
            }
            return blocked("I could not search browser tabs.", detail: error.localizedDescription)
        }
    }

    private func runVisualComputerTask(goal: String, maxSteps: Int?) async -> ActionResult {
        guard OpenAIConfiguration.apiKey() != nil else {
            return blocked("I need an OpenAI API key before I can run visual computer use.", detail: "OpenAIConfiguration.apiKey returned nil.")
        }

        guard AXIsProcessTrusted() else {
            return blocked("Accessibility permission is required before I can operate the screen.", detail: "AXIsProcessTrusted returned false.")
        }

        guard CGPreflightScreenCaptureAccess() else {
            return blocked("Screen Recording permission is required before I can run visual computer use.", detail: "CGPreflightScreenCaptureAccess returned false.")
        }

        do {
            let summary = try await runComputerUseLoop(goal: goal, maxSteps: max(1, min(maxSteps ?? 8, 20)))
            return ActionResult(
                succeeded: true,
                spokenText: "Finished the visual task.",
                detail: summary
            )
        } catch {
            if cancelRequested {
                return cancelledResult()
            }
            return blocked("I could not complete the visual computer-use task.", detail: error.localizedDescription)
        }
    }

    private func runBrowserTask(goal: String, url: String?, maxSteps: Int?, browserBackend: String?, browserProfileMode: String?, browserProfile: String?) async -> ActionResult {
        guard OpenAIConfiguration.apiKey() != nil else {
            return blocked("I need an OpenAI API key before I can run browser selection.", detail: "OpenAIConfiguration.apiKey returned nil.")
        }

        do {
            let backend = resolvedBrowserBackend(browserBackend: browserBackend, browserProfileMode: browserProfileMode)
            let result: BrowserAutomationResult
            if backend == "live_chrome" {
                result = try await chromeLiveAutomation.run(
                    goal: goal,
                    url: url,
                    maxSteps: max(1, min(maxSteps ?? 12, 30))
                )
            } else {
                result = try await browserAutomation.run(
                    goal: goal,
                    url: url,
                    maxSteps: max(1, min(maxSteps ?? 12, 30)),
                    browserBackend: backend,
                    browserProfileMode: browserProfileMode,
                    browserProfile: browserProfile
                )
            }

            let stepSummary = result.steps.isEmpty ? "" : "\n\nSteps:\n- \(result.steps.joined(separator: "\n- "))"
            let finalURL = result.finalURL?.isEmpty == false ? "\n\nFinal URL: \(result.finalURL!)" : ""
            let screenshot = result.screenshotPath?.isEmpty == false ? "\n\nScreenshot: \(result.screenshotPath!)" : ""
            return ActionResult(
                succeeded: result.ok,
                spokenText: result.spokenText,
                detail: "\(result.detail)\(finalURL)\(screenshot)\(stepSummary)"
            )
        } catch {
            if cancelRequested {
                return cancelledResult()
            }
            return blocked("I could not complete the browser task.", detail: error.localizedDescription)
        }
    }

    private func resolvedBrowserBackend(browserBackend: String?, browserProfileMode: String?) -> String {
        if browserBackend == "managed" {
            return "managed"
        }
        if browserBackend == "live_chrome" {
            return "live_chrome"
        }
        if browserProfileMode == "managed" {
            return "managed"
        }
        if browserProfileMode == "existing_chrome" {
            return "live_chrome"
        }
        return "live_chrome"
    }

    private func runComputerUseLoop(goal: String, maxSteps: Int) async throws -> String {
        let model = ProcessInfo.processInfo.environment["CUA_MODEL"] ?? "gpt-5.5"
        var response = try await createOpenAIResponse([
            "model": model,
            "tools": [["type": "computer"]],
            "input": "\(goal)\nUse the computer tool for UI interaction. Stop before sending, purchasing, deleting, authenticating, or exposing sensitive data."
        ])

        var responseID = response["id"] as? String
        var lastScreenshotPath: String?

        for step in 1...maxSteps {
            if let safetyMessage = pendingSafetyMessage(in: response) {
                throw ActionExecutionError(message: safetyMessage)
            }

            guard let call = firstComputerCall(in: response) else {
                return outputText(from: response) ?? "Visual computer-use finished after \(step - 1) step(s). Last screenshot: \(lastScreenshotPath ?? "none")."
            }

            let actions = computerActions(from: call)
            try await executeComputerActions(actions)

            let capture = try await captureScreenshotData(scope: "screen")
            lastScreenshotPath = capture.path.path

            guard let callID = call["call_id"] as? String else {
                throw ActionExecutionError(message: "Computer call did not include a call_id.")
            }

            var body: [String: Any] = [
                "model": model,
                "tools": [["type": "computer"]],
                "input": [
                    [
                        "type": "computer_call_output",
                        "call_id": callID,
                        "output": [
                            "type": "computer_screenshot",
                            "image_url": "data:image/png;base64,\(capture.base64PNG)",
                            "detail": "original"
                        ]
                    ]
                ]
            ]

            if let responseID {
                body["previous_response_id"] = responseID
            }

            response = try await createOpenAIResponse(body)
            responseID = response["id"] as? String
        }

        return outputText(from: response) ?? "Stopped after \(maxSteps) visual computer-use step(s). Last screenshot: \(lastScreenshotPath ?? "none")."
    }

    private func executeComputerActions(_ actions: [[String: Any]]) async throws {
        for action in actions {
            if cancelRequested {
                throw ActionExecutionError(message: "Visual computer-use task was cancelled.")
            }

            guard let type = action["type"] as? String else {
                throw ActionExecutionError(message: "Computer action did not include a type.")
            }

            let result: ActionResult
            switch type {
            case "click":
                result = clickMouse(x: doubleValue(action["x"]), y: doubleValue(action["y"]), button: action["button"] as? String, clickCount: 1, keys: action["keys"] as? [String])
            case "double_click":
                result = clickMouse(x: doubleValue(action["x"]), y: doubleValue(action["y"]), button: action["button"] as? String, clickCount: 2, keys: action["keys"] as? [String])
            case "move":
                result = moveMouse(x: doubleValue(action["x"]), y: doubleValue(action["y"]), keys: action["keys"] as? [String])
            case "scroll":
                result = scrollByDelta(
                    scrollX: doubleValue(action["scrollX"]) ?? 0,
                    scrollY: doubleValue(action["scrollY"]) ?? 0,
                    x: doubleValue(action["x"]),
                    y: doubleValue(action["y"]),
                    keys: action["keys"] as? [String]
                )
            case "keypress":
                result = pressKeys(action["keys"] as? [String])
            case "type":
                result = typeText(action["text"] as? String)
            case "drag":
                result = dragComputerAction(action)
            case "wait":
                try await Task.sleep(for: .seconds(2))
                result = ActionResult(succeeded: true, spokenText: "Waited.", detail: "Waited for UI state to settle.")
            case "screenshot":
                result = ActionResult(succeeded: true, spokenText: "Screenshot requested.", detail: "Screenshot is captured after each computer-use action batch.")
            default:
                throw ActionExecutionError(message: "Unsupported visual computer action: \(type).")
            }

            if !result.succeeded {
                throw ActionExecutionError(message: result.detail)
            }
        }
    }

    private func dragComputerAction(_ action: [String: Any]) -> ActionResult {
        if let path = action["path"] as? [[String: Any]],
           let first = path.first,
           let last = path.last {
            return dragMouse(
                startX: doubleValue(first["x"]),
                startY: doubleValue(first["y"]),
                endX: doubleValue(last["x"]),
                endY: doubleValue(last["y"]),
                keys: action["keys"] as? [String]
            )
        }

        if let path = action["path"] as? [[Any]],
           let first = path.first,
           let last = path.last,
           first.count >= 2,
           last.count >= 2 {
            return dragMouse(
                startX: doubleValue(first[0]),
                startY: doubleValue(first[1]),
                endX: doubleValue(last[0]),
                endY: doubleValue(last[1]),
                keys: action["keys"] as? [String]
            )
        }

        return blocked("I need a drag path.", detail: "Computer drag action omitted a valid path.")
    }

    private func createOpenAIResponse(_ body: [String: Any]) async throws -> [String: Any] {
        guard let apiKey = OpenAIConfiguration.apiKey() else {
            throw ActionExecutionError(message: "Missing OpenAI API key.")
        }

        guard let url = URL(string: "https://api.openai.com/v1/responses") else {
            throw ActionExecutionError(message: "Invalid OpenAI Responses URL.")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ActionExecutionError(message: "OpenAI returned a non-HTTP response.")
        }

        guard (200..<300).contains(http.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "OpenAI request failed."
            throw ActionExecutionError(message: "OpenAI \(http.statusCode): \(message)")
        }

        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ActionExecutionError(message: "OpenAI returned invalid JSON.")
        }

        return object
    }

    private func firstComputerCall(in response: [String: Any]) -> [String: Any]? {
        guard let output = response["output"] as? [[String: Any]] else { return nil }
        return output.first { ($0["type"] as? String) == "computer_call" }
    }

    private func computerActions(from call: [String: Any]) -> [[String: Any]] {
        if let actions = call["actions"] as? [[String: Any]] {
            return actions
        }

        if let action = call["action"] as? [String: Any] {
            return [action]
        }

        return []
    }

    private func pendingSafetyMessage(in response: [String: Any]) -> String? {
        guard let call = firstComputerCall(in: response),
              let checks = call["pending_safety_checks"] as? [[String: Any]],
              !checks.isEmpty else {
            return nil
        }

        let labels = checks.compactMap { $0["code"] as? String }.joined(separator: ", ")
        return "The computer-use model requested safety acknowledgement before continuing: \(labels)."
    }

    private func outputText(from value: Any?) -> String? {
        if let string = value as? String {
            return string
        }

        if let array = value as? [Any] {
            for item in array {
                if let found = outputText(from: item) {
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

            for key in ["output_text", "content", "output", "message"] {
                if let found = outputText(from: dictionary[key]) {
                    return found
                }
            }
        }

        return nil
    }

    private func captureScreenshotData(scope: String?) async throws -> ScreenshotCapture {
        try FileManager.default.createDirectory(at: screenshotDirectory, withIntermediateDirectories: true)

        let image = try await screenshotImage(scope: scope)

        let rep = NSBitmapImageRep(cgImage: image)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            throw ActionExecutionError(message: "Could not encode screenshot as PNG.")
        }

        let timestamp = Int(Date().timeIntervalSince1970)
        let path = screenshotDirectory.appendingPathComponent("screenshot-\(timestamp).png")
        try data.write(to: path, options: .atomic)

        return ScreenshotCapture(
            path: path,
            base64PNG: data.base64EncodedString(),
            width: image.width,
            height: image.height
        )
    }

    private func screenshotImage(scope: String?) async throws -> CGImage {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)

        switch scope {
        case "active_window", "focused_app":
            if let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
               let window = content.windows.first(where: { window in
                   window.owningApplication?.processID == pid &&
                       window.windowLayer == 0 &&
                       window.isOnScreen
               }) {
                let filter = SCContentFilter(desktopIndependentWindow: window)
                let config = screenshotConfiguration(width: window.frame.width, height: window.frame.height, scale: filter.pointPixelScale)
                config.ignoreShadowsSingleWindow = true
                return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            }
            fallthrough
        default:
            guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) ?? content.displays.first else {
                throw ActionExecutionError(message: "No capturable display was available.")
            }
            let filter = SCContentFilter(display: display, excludingWindows: [])
            if #available(macOS 14.2, *) {
                filter.includeMenuBar = true
            }
            let config = screenshotConfiguration(width: CGFloat(display.width), height: CGFloat(display.height), scale: filter.pointPixelScale)
            return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        }
    }

    private func screenshotConfiguration(width: CGFloat, height: CGFloat, scale: Float) -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        let scale = CGFloat(max(scale, 1))
        config.width = max(1, Int(width * scale))
        config.height = max(1, Int(height * scale))
        config.showsCursor = true
        config.capturesAudio = false
        config.captureResolution = .best
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.queueDepth = 1
        return config
    }

    private func accessibilityRoot(appName: String?, scope: String?) -> AXUIElement? {
        let appElement: AXUIElement
        if let appName = nonEmpty(appName),
           let app = runningApplication(named: appName) {
            appElement = AXUIElementCreateApplication(app.processIdentifier)
        } else if let frontmost = NSWorkspace.shared.frontmostApplication {
            appElement = AXUIElementCreateApplication(frontmost.processIdentifier)
        } else {
            return nil
        }

        if scope == "active_window" || scope == nil {
            if let focusedWindowValue = copyAXAttribute(appElement, kAXFocusedWindowAttribute) {
                let focusedWindow = focusedWindowValue as! AXUIElement
                return focusedWindow
            }
        }

        return appElement
    }

    private func collectAccessibilitySummary(_ element: AXUIElement, depth: Int, maxDepth: Int, maxElements: Int, lines: inout [String]) {
        guard depth <= maxDepth, lines.count < maxElements else { return }

        let summary = accessibilitySummary(element)
        if !summary.isEmpty {
            lines.append("\(String(repeating: "  ", count: depth))- \(summary)")
        }

        guard let children = copyAXAttribute(element, kAXChildrenAttribute) as? [AXUIElement] else { return }
        for child in children {
            collectAccessibilitySummary(child, depth: depth + 1, maxDepth: maxDepth, maxElements: maxElements, lines: &lines)
            if lines.count >= maxElements { break }
        }
    }

    private func findAccessibilityElement(_ element: AXUIElement, label: String, role: String?, maxDepth: Int, maxElements: Int) -> AccessibilityMatch? {
        var visited = 0
        return findAccessibilityElement(
            element,
            label: label.localizedLowercase,
            role: role?.localizedLowercase,
            depth: 0,
            maxDepth: maxDepth,
            maxElements: maxElements,
            visited: &visited
        )
    }

    private func findAccessibilityElement(
        _ element: AXUIElement,
        label: String,
        role: String?,
        depth: Int,
        maxDepth: Int,
        maxElements: Int,
        visited: inout Int
    ) -> AccessibilityMatch? {
        guard depth <= maxDepth, visited < maxElements else { return nil }
        visited += 1

        let summary = accessibilitySummary(element)
        if accessibilityElement(element, matchesLabel: label, role: role) {
            return AccessibilityMatch(element: element, summary: summary)
        }

        guard let children = copyAXAttribute(element, kAXChildrenAttribute) as? [AXUIElement] else { return nil }
        for child in children {
            if let match = findAccessibilityElement(
                child,
                label: label,
                role: role,
                depth: depth + 1,
                maxDepth: maxDepth,
                maxElements: maxElements,
                visited: &visited
            ) {
                return match
            }
        }

        return nil
    }

    private func accessibilityElement(_ element: AXUIElement, matchesLabel label: String, role roleFilter: String?) -> Bool {
        let haystack = [
            stringAXAttribute(element, kAXTitleAttribute),
            stringAXAttribute(element, kAXDescriptionAttribute),
            stringAXAttribute(element, kAXValueAttribute),
            stringAXAttribute(element, kAXHelpAttribute)
        ]
            .compactMap(\.self)
            .joined(separator: " ")
            .localizedLowercase

        guard haystack.contains(label) else { return false }

        guard let roleFilter, !roleFilter.isEmpty else { return true }
        let role = (stringAXAttribute(element, kAXRoleAttribute) ?? "")
            .replacingOccurrences(of: "AX", with: "")
            .localizedLowercase
        return role.contains(roleFilter.replacingOccurrences(of: " ", with: ""))
    }

    private func accessibilitySummary(_ element: AXUIElement) -> String {
        let role = stringAXAttribute(element, kAXRoleAttribute) ?? "AXElement"
        let title = stringAXAttribute(element, kAXTitleAttribute)
        let value = stringAXAttribute(element, kAXValueAttribute)
        let description = stringAXAttribute(element, kAXDescriptionAttribute)
        let actions = actionNames(element).joined(separator: ",")
        let frame = accessibilityFrame(element).map { "frame=\(Int($0.origin.x)),\(Int($0.origin.y)),\(Int($0.width))x\(Int($0.height))" }
        let label = [title, value, description]
            .compactMap { value in
                guard let value, !value.isEmpty else { return nil }
                return value
            }
            .prefix(2)
            .joined(separator: " | ")

        return [
            role,
            label.isEmpty ? nil : "\"\(label)\"",
            actions.isEmpty ? nil : "actions=\(actions)",
            frame
        ]
            .compactMap(\.self)
            .joined(separator: " ")
    }

    private func performPress(on element: AXUIElement) -> Bool {
        let actions = actionNames(element)
        guard actions.contains(kAXPressAction as String) else { return false }
        return AXUIElementPerformAction(element, kAXPressAction as CFString) == .success
    }

    private func actionNames(_ element: AXUIElement) -> [String] {
        var names: CFArray?
        guard AXUIElementCopyActionNames(element, &names) == .success,
              let names = names as? [String] else {
            return []
        }
        return names
    }

    private func accessibilityFrame(_ element: AXUIElement) -> CGRect? {
        guard let positionValue = copyAXAttribute(element, kAXPositionAttribute),
              let sizeValue = copyAXAttribute(element, kAXSizeAttribute),
              CFGetTypeID(positionValue) == AXValueGetTypeID(),
              CFGetTypeID(sizeValue) == AXValueGetTypeID() else {
            return nil
        }

        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &position),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) else {
            return nil
        }

        return CGRect(origin: position, size: size)
    }

    private func copyAXAttribute(_ element: AXUIElement, _ attribute: String) -> AnyObject? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value
    }

    private func stringAXAttribute(_ element: AXUIElement, _ attribute: String) -> String? {
        guard let value = copyAXAttribute(element, attribute) else { return nil }
        if let string = value as? String {
            return string
        }
        if let number = value as? NSNumber {
            return number.stringValue
        }
        return nil
    }

    private func performWithHeldKeys(_ keys: [String]?, action: () -> Void) -> ActionResult? {
        let normalizedKeys = (keys ?? [])
            .map(normalizeKeyName)
            .filter { !$0.isEmpty }

        guard !normalizedKeys.isEmpty else {
            action()
            return nil
        }

        var heldKeyCodes: [CGKeyCode] = []
        for key in normalizedKeys {
            guard let keyCode = modifierKeyCodes[key] ?? keyCodes[key] else {
                return blocked("I do not know that modifier key.", detail: "Unsupported held key for mouse action: \(key).")
            }
            heldKeyCodes.append(keyCode)
        }

        let source = CGEventSource(stateID: .combinedSessionState)
        for keyCode in heldKeyCodes {
            CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)?
                .post(tap: .cghidEventTap)
        }

        action()

        for keyCode in heldKeyCodes.reversed() {
            CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)?
                .post(tap: .cghidEventTap)
        }

        return nil
    }

    private func postMouseMove(to point: CGPoint) {
        let source = CGEventSource(stateID: .combinedSessionState)
        let event = CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)
        event?.post(tap: .cghidEventTap)
    }

    private func postMouseClick(at point: CGPoint, button: MouseButtonSpec, clickCount: Int) {
        postMouseMove(to: point)

        for clickIndex in 1...clickCount {
            let source = CGEventSource(stateID: .combinedSessionState)
            let down = CGEvent(mouseEventSource: source, mouseType: button.downType, mouseCursorPosition: point, mouseButton: button.button)
            down?.setIntegerValueField(.mouseEventClickState, value: Int64(clickIndex))
            down?.post(tap: .cghidEventTap)

            let up = CGEvent(mouseEventSource: source, mouseType: button.upType, mouseCursorPosition: point, mouseButton: button.button)
            up?.setIntegerValueField(.mouseEventClickState, value: Int64(clickIndex))
            up?.post(tap: .cghidEventTap)
        }
    }

    private func postMouseDrag(from start: CGPoint, to end: CGPoint) {
        let source = CGEventSource(stateID: .combinedSessionState)
        postMouseMove(to: start)

        CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: start, mouseButton: .left)?
            .post(tap: .cghidEventTap)

        let steps = 16
        for index in 1...steps {
            let progress = CGFloat(index) / CGFloat(steps)
            let point = CGPoint(
                x: start.x + (end.x - start.x) * progress,
                y: start.y + (end.y - start.y) * progress
            )
            CGEvent(mouseEventSource: source, mouseType: .leftMouseDragged, mouseCursorPosition: point, mouseButton: .left)?
                .post(tap: .cghidEventTap)
        }

        CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: end, mouseButton: .left)?
            .post(tap: .cghidEventTap)
    }

    private func pointFrom(x: Double?, y: Double?) -> CGPoint? {
        guard let x, let y else { return nil }
        return CGPoint(x: x, y: y)
    }

    private func mouseButton(named name: String?) -> MouseButtonSpec {
        switch name?.lowercased() {
        case "right":
            return .right
        case "middle", "center":
            return .middle
        default:
            return .left
        }
    }

    private func focusAppIfProvided(_ appName: String?) async throws {
        guard let appName = nonEmpty(appName) else { return }
        if let app = runningApplication(named: appName) {
            app.activate(options: [.activateAllWindows])
            try await Task.sleep(for: .milliseconds(180))
            return
        }

        try await run("/usr/bin/open", ["-a", appName])
        try await Task.sleep(for: .milliseconds(300))
    }

    private func runningApplication(named name: String) -> NSRunningApplication? {
        let normalized = name.localizedLowercase
        return NSWorkspace.shared.runningApplications.first { app in
            guard let localizedName = app.localizedName?.localizedLowercase else { return false }
            return localizedName == normalized || localizedName.contains(normalized) || normalized.contains(localizedName)
        }
    }

    private func browserAppName(from appName: String?) -> String {
        guard let appName = nonEmpty(appName) else { return "Google Chrome" }
        if appName.localizedCaseInsensitiveContains("safari") {
            return "Safari"
        }
        if appName.localizedCaseInsensitiveContains("chrome") {
            return "Google Chrome"
        }
        return appName
    }

    private func chromeFindTabScript(query: String) -> String {
        let query = appleScriptEscaped(query)
        return """
        tell application "Google Chrome"
          activate
          repeat with w in windows
            set tabIndex to 0
            repeat with t in tabs of w
              set tabIndex to tabIndex + 1
              if ((title of t) contains "\(query)") or ((URL of t) contains "\(query)") then
                set active tab index of w to tabIndex
                set index of w to 1
                return title of t
              end if
            end repeat
          end repeat
        end tell
        return "__NOT_FOUND__"
        """
    }

    private func safariFindTabScript(query: String) -> String {
        let query = appleScriptEscaped(query)
        return """
        tell application "Safari"
          activate
          repeat with w in windows
            set tabIndex to 0
            repeat with t in tabs of w
              set tabIndex to tabIndex + 1
              if ((name of t) contains "\(query)") or ((URL of t) contains "\(query)") then
                set current tab of w to t
                set index of w to 1
                return name of t
              end if
            end repeat
          end repeat
        end tell
        return "__NOT_FOUND__"
        """
    }

    private func systemEventsMenuClickScript(appName: String, tokens: [String]) -> String {
        let appName = appleScriptEscaped(appName)
        var container = "menu \"\(appleScriptEscaped(tokens[0]))\" of menu bar 1"
        if tokens.count > 2 {
            for token in tokens.dropFirst().dropLast() {
                let escaped = appleScriptEscaped(token)
                container = "menu \"\(escaped)\" of menu item \"\(escaped)\" of \(container)"
            }
        }
        let final = appleScriptEscaped(tokens[tokens.count - 1])
        return """
        tell application "System Events"
          tell process "\(appName)"
            click menu item "\(final)" of \(container)
          end tell
        end tell
        """
    }

    private func runAppleScript(_ script: String) async throws {
        try await run("/usr/bin/osascript", ["-e", script])
    }

    private func run(_ executable: String, _ arguments: [String]) async throws {
        _ = try await runReturningOutput(executable, arguments)
    }

    private func runReturningOutput(_ executable: String, _ arguments: [String]) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            currentProcess = process

            let outputPipe = Pipe()
            let errorPipe = Pipe()
            process.standardOutput = outputPipe
            process.standardError = errorPipe
            process.terminationHandler = { process in
                Task { @MainActor [weak self] in
                    if self?.currentProcess === process {
                        self?.currentProcess = nil
                    }
                }

                let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
                let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: outputData, encoding: .utf8) ?? ""

                if process.terminationStatus == 0 {
                    continuation.resume(returning: output)
                    return
                }

                let message = String(data: errorData, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                continuation.resume(throwing: ActionExecutionError(message: message ?? "Process failed."))
            }

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    private func nonEmpty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    private func normalizedOpenURL(_ value: String) -> URL? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard let url = URL(string: candidate),
              let scheme = url.scheme?.lowercased(),
              ["http", "https", "chrome"].contains(scheme) else {
            return nil
        }

        return url
    }

    private func displayName(for url: URL) -> String {
        if url.scheme?.lowercased() == "chrome", url.host()?.lowercased() == "newtab" {
            return "a new tab"
        }

        return url.host() ?? url.absoluteString
    }

    private func appleScriptEscaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private func normalizeKeyName(_ key: String) -> String {
        let key = key.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        switch key {
        case "return", "enter":
            return "return"
        case "esc":
            return "escape"
        case "arrowleft":
            return "left"
        case "arrowright":
            return "right"
        case "arrowup":
            return "up"
        case "arrowdown":
            return "down"
        case "pageup", "page_up":
            return "pageup"
        case "pagedown", "page_down":
            return "pagedown"
        case "cmd", "command", "meta":
            return "cmd"
        case "ctrl":
            return "control"
        case "alt":
            return "option"
        default:
            return key
        }
    }

    private func requireAccessibility() -> ActionResult? {
        guard AXIsProcessTrusted() else {
            return blocked(
                "Accessibility permission is required before I can control apps.",
                detail: "AXIsProcessTrusted returned false."
            )
        }
        return nil
    }

    private func blocked(_ spoken: String, detail: String) -> ActionResult {
        ActionResult(succeeded: false, spokenText: spoken, detail: detail)
    }

    private func cancelledResult() -> ActionResult {
        ActionResult(
            succeeded: false,
            spokenText: "Cancelled.",
            detail: "Cancelled the current native action after the user interrupted."
        )
    }

    private func doubleValue(_ value: Any?) -> Double? {
        if let value = value as? Double { return value }
        if let value = value as? Int { return Double(value) }
        if let value = value as? NSNumber { return value.doubleValue }
        if let value = value as? String { return Double(value) }
        return nil
    }

    private let modifierNames: Set<String> = ["cmd", "command", "meta", "shift", "option", "alt", "control", "ctrl"]

    private let modifierKeyCodes: [String: CGKeyCode] = [
        "cmd": 55,
        "command": 55,
        "meta": 55,
        "shift": 56,
        "option": 58,
        "alt": 58,
        "control": 59,
        "ctrl": 59
    ]

    private let keyCodes: [String: CGKeyCode] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7,
        "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14, "r": 15,
        "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22,
        "5": 23, "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29,
        "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35,
        "return": 36, "enter": 36, "l": 37, "j": 38, "'": 39, "k": 40,
        ";": 41, "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46, ".": 47,
        "tab": 48, "space": 49, "delete": 51, "backspace": 51, "escape": 53,
        "esc": 53, "left": 123, "right": 124, "down": 125, "up": 126,
        "home": 115, "end": 119, "pageup": 116, "pagedown": 121
    ]
}

private struct ScreenshotCapture {
    var path: URL
    var base64PNG: String
    var width: Int
    var height: Int
}

private struct AccessibilityMatch {
    var element: AXUIElement
    var summary: String
}

private struct MouseButtonSpec {
    var name: String
    var button: CGMouseButton
    var downType: CGEventType
    var upType: CGEventType

    static let left = MouseButtonSpec(name: "left", button: .left, downType: .leftMouseDown, upType: .leftMouseUp)
    static let right = MouseButtonSpec(name: "right", button: .right, downType: .rightMouseDown, upType: .rightMouseUp)
    static let middle = MouseButtonSpec(name: "middle", button: .center, downType: .otherMouseDown, upType: .otherMouseUp)
}

private struct ActionExecutionError: LocalizedError {
    var message: String
    var errorDescription: String? { message }
}
