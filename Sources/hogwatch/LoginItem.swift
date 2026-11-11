import Foundation

/// "Open at login", implemented as a per-user LaunchAgent: the same file
/// install.sh writes. No administrator rights are involved.
enum LoginItem {
    static let label = "com.hogwatch.agent"

    private static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    static var isEnabled: Bool {
        FileManager.default.fileExists(atPath: plistURL.path)
    }

    /// Returns true when the change was applied. Takes effect at the next login.
    @discardableResult
    static func setEnabled(_ enabled: Bool) -> Bool {
        let fileManager = FileManager.default
        do {
            if enabled {
                guard let executable = Bundle.main.executablePath else { return false }
                let plist: [String: Any] = [
                    "Label": label,
                    "ProgramArguments": [executable],
                    "RunAtLoad": true,
                    "KeepAlive": false,
                    "ProcessType": "Interactive",
                ]
                let data = try PropertyListSerialization.data(
                    fromPropertyList: plist, format: .xml, options: 0
                )
                try fileManager.createDirectory(
                    at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true
                )
                try data.write(to: plistURL, options: .atomic)
            } else if fileManager.fileExists(atPath: plistURL.path) {
                try fileManager.removeItem(at: plistURL)
            }
            return true
        } catch {
            return false
        }
    }
}
