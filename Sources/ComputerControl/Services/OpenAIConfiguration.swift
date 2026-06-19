import CryptoKit
import Foundation

enum OpenAIConfiguration {
    static func apiKey() -> String? {
        if let key = ProcessInfo.processInfo.environment["OPENAI_API_KEY"], !key.isEmpty {
            return key
        }

        for localURL in envCandidates() {
            if let key = envValue(named: "OPENAI_API_KEY", from: localURL), !key.isEmpty {
                return key
            }
        }

        for localURL in openAIKeyCandidates() {
            if let key = try? String(contentsOf: localURL, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !key.isEmpty {
                return key
            }
        }

        return nil
    }

    static func safetyIdentifier() -> String {
        let raw = NSUserName().isEmpty ? "local-native-control-user" : NSUserName()
        let digest = SHA256.hash(data: Data(raw.utf8))
        return digest.map { String(format: "%02x", $0) }.joined().prefix(32).description
    }

    private static func envCandidates() -> [URL] {
        projectRootCandidates().map { $0.appendingPathComponent(".env") }
    }

    private static func openAIKeyCandidates() -> [URL] {
        projectRootCandidates().map { $0.appendingPathComponent(".openai") }
    }

    private static func projectRootCandidates() -> [URL] {
        let workingDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let projectFromBundle = Bundle.main.bundleURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let home = FileManager.default.homeDirectoryForCurrentUser

        return [workingDirectory, projectFromBundle, home]
    }

    private static func envValue(named name: String, from url: URL) -> String? {
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else {
            return nil
        }

        for line in contents.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }

            let prefix = "\(name)="
            guard trimmed.hasPrefix(prefix) else { continue }

            var value = String(trimmed.dropFirst(prefix.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)

            if (value.hasPrefix("\"") && value.hasSuffix("\"")) ||
                (value.hasPrefix("'") && value.hasSuffix("'")) {
                value.removeFirst()
                value.removeLast()
            }

            return value
        }

        return nil
    }
}
