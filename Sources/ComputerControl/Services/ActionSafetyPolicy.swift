import Foundation

enum ActionSafetyPolicy {
    static func blockedReason(for plan: PlannedAction, safetyMode: SafetyMode) -> String? {
        if let reason = highImpactReason(in: safetyText(for: plan)) {
            return reason
        }

        if safetyMode == .strictPreview && plan.risk != "safe" {
            return "Strict preview mode blocks write or control actions unless they are explicitly marked safe."
        }

        return nil
    }

    static func highImpactReason(in text: String) -> String? {
        let normalized = text.localizedLowercase
        for phrase in highImpactPhrases where normalized.contains(phrase) {
            return "High-impact action needs explicit confirmation first: \(phrase)."
        }
        return nil
    }

    private static func safetyText(for plan: PlannedAction) -> String {
        [
            plan.action.rawValue,
            plan.text,
            plan.spokenText,
            plan.rationale,
            plan.url,
            plan.appName,
            plan.elementLabel,
            plan.role,
            plan.menuPath,
            plan.tabQuery,
            plan.browserBackend,
            plan.browserProfileMode,
            plan.browserProfile,
            plan.keys?.joined(separator: " "),
        ]
        .compactMap(\.self)
        .joined(separator: " ")
    }

    private static let highImpactPhrases = [
        "send",
        "submit",
        "buy",
        "purchase",
        "pay",
        "checkout",
        "delete",
        "destroy",
        "erase",
        "remove file",
        "rm -rf",
        "upload",
        "share",
        "post",
        "publish",
        "authenticate",
        "log in",
        "login",
        "password",
        "credential",
        "permission change",
        "grant permission",
    ]
}
