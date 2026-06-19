import AppKit
import SwiftUI

@MainActor
final class ComputerControlServices {
    static let shared = ComputerControlServices()

    let permissionStore = PermissionStore()
    let commandStore = CommandStore()
    let speechStore = SpeechStore()
    let chromeLiveAutomationService: ChromeLiveAutomationService
    let actionService: AppActionService
    let voiceService = VoiceCommandService()
    let realtimeVoiceService = RealtimeWebRTCService()
    let plannerService = OpenAIPlannerService()

    private init() {
        chromeLiveAutomationService = ChromeLiveAutomationService()
        actionService = AppActionService(chromeLiveAutomation: chromeLiveAutomationService)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var mainWindow: NSWindow?
    private let services = ComputerControlServices.shared

    func applicationDidFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.set(false, forKey: "NSQuitAlwaysKeepsWindows")
        NSApp.setActivationPolicy(.regular)
        showMainWindow()
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        false
    }

    func application(_ app: NSApplication, shouldSaveApplicationState coder: NSCoder) -> Bool {
        false
    }

    func application(_ app: NSApplication, shouldRestoreApplicationState coder: NSCoder) -> Bool {
        false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMainWindow()
        return true
    }

    func windowWillClose(_ notification: Notification) {
        guard notification.object as? NSWindow === mainWindow else { return }
        mainWindow = nil
    }

    private func showMainWindow() {
        if let mainWindow {
            mainWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let rootView = ContentView()
            .environment(services.permissionStore)
            .environment(services.commandStore)
            .environment(services.speechStore)
            .environment(services.actionService)
            .environment(services.chromeLiveAutomationService)
            .environment(services.voiceService)
            .environment(services.realtimeVoiceService)
            .environment(services.plannerService)
            .frame(minWidth: 1120, minHeight: 720)

        let hostingController = NSHostingController(rootView: rootView)
        let window = NSWindow(
            contentRect: NSRect(x: 175, y: 75, width: 1120, height: 772),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Computer Control"
        window.identifier = NSUserInterfaceItemIdentifier("main")
        window.contentViewController = hostingController
        window.delegate = self
        window.setFrameAutosaveName("main")
        window.center()
        window.makeKeyAndOrderFront(nil)
        mainWindow = window
        NSApp.activate(ignoringOtherApps: true)
    }
}

@main
struct ComputerControlApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    private let services = ComputerControlServices.shared

    var body: some Scene {
        Settings {
            SettingsView()
                .environment(services.permissionStore)
                .environment(services.commandStore)
                .environment(services.speechStore)
                .environment(services.actionService)
                .environment(services.chromeLiveAutomationService)
                .environment(services.voiceService)
                .environment(services.realtimeVoiceService)
                .environment(services.plannerService)
                .frame(width: 520)
        }
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Refresh Permissions") {
                    services.permissionStore.refresh()
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            }
        }
    }
}
