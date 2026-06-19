import Foundation

enum AppPaths {
    static let supportDirectoryName = "ComputerControl"
    static let legacySupportDirectoryName = "ComputerControlShell"

    static func applicationSupportDirectory(name: String = supportDirectoryName) -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return base.appendingPathComponent(name, isDirectory: true)
    }

    static func migratedSupportFile(named filename: String) -> URL {
        let preferred = applicationSupportDirectory()
            .appendingPathComponent(filename)
        let legacy = applicationSupportDirectory(name: legacySupportDirectoryName)
            .appendingPathComponent(filename)

        guard !FileManager.default.fileExists(atPath: preferred.path),
              FileManager.default.fileExists(atPath: legacy.path) else {
            return preferred
        }

        do {
            try FileManager.default.createDirectory(
                at: preferred.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try FileManager.default.copyItem(at: legacy, to: preferred)
        } catch {
            return legacy
        }

        return preferred
    }

    static func managedBrowserProfileDirectory() -> URL {
        let preferred = applicationSupportDirectory()
            .appendingPathComponent("ManagedChromium", isDirectory: true)
        let legacy = applicationSupportDirectory(name: legacySupportDirectoryName)
            .appendingPathComponent("ManagedChromium", isDirectory: true)

        if !FileManager.default.fileExists(atPath: preferred.path),
           FileManager.default.fileExists(atPath: legacy.path) {
            return legacy
        }

        return preferred
    }

    static func projectRootCandidates() -> [URL] {
        var candidates: [URL] = []
        let fileManager = FileManager.default

        if let configuredRoot = ProcessInfo.processInfo.environment["COMPUTER_CONTROL_ROOT"],
           !configuredRoot.isEmpty {
            candidates.append(URL(fileURLWithPath: configuredRoot))
        }

        candidates.append(URL(fileURLWithPath: fileManager.currentDirectoryPath))

        let projectFromBundle = Bundle.main.bundleURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        candidates.append(projectFromBundle)

        if let resourceURL = Bundle.main.resourceURL {
            candidates.append(resourceURL)
        }

        var seen = Set<String>()
        return candidates.map(\.standardizedFileURL).filter { candidate in
            seen.insert(candidate.path).inserted
        }
    }
}
