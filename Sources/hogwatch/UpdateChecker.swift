import Foundation

/// Checks GitHub once a day for a newer release and reports it.
///
/// This is the only network request hogwatch makes. It asks GitHub's public
/// API for the latest release of the repository and sends nothing about the
/// user or the Mac. It never downloads or installs anything.
@MainActor
final class UpdateChecker {
    static let apiURL = URL(string: "https://api.github.com/repos/louiscada/hogwatch/releases/latest")!
    static let releasePage = URL(string: "https://github.com/louiscada/hogwatch/releases/latest")!

    private static let interval: TimeInterval = 24 * 60 * 60
    private static let lastCheckKey = "lastUpdateCheck"
    private static let availableKey = "availableVersion"

    /// Called on the main thread with the newer version, or nil when
    /// hogwatch is up to date.
    var onChange: (String?) -> Void = { _ in }

    private let defaults: UserDefaults
    private var isChecking = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// A newer version found by an earlier check, if it is still newer
    /// than the one running.
    var knownNewerVersion: String? {
        guard let stored = defaults.string(forKey: Self.availableKey),
              Self.isVersion(stored, newerThan: Settings.version)
        else { return nil }
        return stored
    }

    /// Starts a check if a day has passed since the last one.
    func checkIfDue() {
        let last = defaults.double(forKey: Self.lastCheckKey)
        let now = Date().timeIntervalSince1970
        guard !isChecking, now - last >= Self.interval else { return }

        isChecking = true
        // Recorded up front, so a failed check waits a day before retrying.
        defaults.set(now, forKey: Self.lastCheckKey)

        var request = URLRequest(url: Self.apiURL)
        request.timeoutInterval = 15
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        let task = URLSession.shared.dataTask(with: request) { [weak self] data, _, _ in
            let latest = data.flatMap { Self.latestVersion(in: $0) }
            Task { @MainActor [weak self] in
                self?.finish(latest: latest)
            }
        }
        task.resume()
    }

    private func finish(latest: String?) {
        isChecking = false
        // Offline, no releases yet, or an unexpected reply: stay silent.
        guard let latest = latest else { return }

        if Self.isVersion(latest, newerThan: Settings.version) {
            defaults.set(latest, forKey: Self.availableKey)
            onChange(latest)
        } else {
            defaults.removeObject(forKey: Self.availableKey)
            onChange(nil)
        }
    }

    /// Pulls "0.3.1" out of the release's tag ("v0.3.1").
    nonisolated private static func latestVersion(in data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let release = object as? [String: Any],
              let tag = release["tag_name"] as? String
        else { return nil }

        var version = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        if version.hasPrefix("v") || version.hasPrefix("V") {
            version.removeFirst()
        }
        return numbers(in: version).isEmpty ? nil : version
    }

    /// Compares dotted versions number by number: 0.10.0 is newer than 0.9.2.
    nonisolated static func isVersion(_ candidate: String, newerThan current: String) -> Bool {
        let left = numbers(in: candidate)
        let right = numbers(in: current)
        for index in 0..<max(left.count, right.count) {
            let a = index < left.count ? left[index] : 0
            let b = index < right.count ? right[index] : 0
            if a != b { return a > b }
        }
        return false
    }

    nonisolated private static func numbers(in version: String) -> [Int] {
        version.split(separator: ".").compactMap { part in
            Int(part.prefix { $0.isNumber })
        }
    }
}
