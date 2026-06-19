import Foundation

struct ControllableApp: Identifiable, Hashable {
    var id: String { bundleID }
    var displayName: String
    var bundleID: String
    var fallbackPaths: [String]
    var aliases: [String]

    static let allowed: [ControllableApp] = [
        ControllableApp(
            displayName: "Calculator",
            bundleID: "com.apple.calculator",
            fallbackPaths: ["/System/Applications/Calculator.app", "/Applications/Calculator.app"],
            aliases: ["calculator", "calc"]
        ),
        ControllableApp(
            displayName: "Calendar",
            bundleID: "com.apple.iCal",
            fallbackPaths: ["/System/Applications/Calendar.app", "/Applications/Calendar.app"],
            aliases: ["calendar", "cal"]
        ),
        ControllableApp(
            displayName: "Safari",
            bundleID: "com.apple.Safari",
            fallbackPaths: ["/Applications/Safari.app"],
            aliases: ["safari", "browser"]
        ),
        ControllableApp(
            displayName: "Notes",
            bundleID: "com.apple.Notes",
            fallbackPaths: ["/System/Applications/Notes.app", "/Applications/Notes.app"],
            aliases: ["notes", "note"]
        ),
        ControllableApp(
            displayName: "TextEdit",
            bundleID: "com.apple.TextEdit",
            fallbackPaths: ["/System/Applications/TextEdit.app", "/Applications/TextEdit.app"],
            aliases: ["textedit", "text edit"]
        )
    ]
}

struct ActionResult {
    var succeeded: Bool
    var spokenText: String
    var detail: String
}
