import Combine
import Foundation

/// A small log of past alerts, so Settings can show which apps keep
/// setting hogwatch off. Kept for 30 days, on this Mac only.
final class AlertHistory: ObservableObject {
    struct Record {
        let date: Date
        /// "cpu", "memory", "runaway" or "battery".
        let kind: String
        /// The app held responsible; empty when none stood out.
        let app: String
    }

    struct AppCount: Identifiable {
        let name: String
        let count: Int
        var id: String { name }
    }

    @Published private(set) var records: [Record] = []

    private let defaults: UserDefaults
    private let key = "alertHistory"
    private static let maxAge: TimeInterval = 30 * 24 * 60 * 60
    private static let maxRecords = 300

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stored = defaults.array(forKey: key) as? [[String: Any]] ?? []
        records = stored.compactMap { entry in
            guard let time = entry["t"] as? Double,
                  let kind = entry["k"] as? String
            else { return nil }
            return Record(
                date: Date(timeIntervalSince1970: time),
                kind: kind,
                app: entry["a"] as? String ?? ""
            )
        }
    }

    func record(kind: String, app: String) {
        let cutoff = Date().addingTimeInterval(-Self.maxAge)
        var updated = records.filter { $0.date >= cutoff }
        updated.append(Record(date: Date(), kind: kind, app: app))
        if updated.count > Self.maxRecords {
            updated.removeFirst(updated.count - Self.maxRecords)
        }
        records = updated
        save()
    }

    func clear() {
        records = []
        defaults.removeObject(forKey: key)
    }

    /// Alerts in the last seven days.
    var weekTotal: Int {
        recentRecords.count
    }

    /// Alerts blamed on one app in the last seven days.
    func weekCount(forApp name: String) -> Int {
        recentRecords.reduce(0) { $1.app == name ? $0 + 1 : $0 }
    }

    /// The apps behind the most alerts in the last seven days, busiest first.
    var weekTopApps: [AppCount] {
        var counts: [String: Int] = [:]
        for record in recentRecords where !record.app.isEmpty {
            counts[record.app, default: 0] += 1
        }
        return counts
            .map { AppCount(name: $0.key, count: $0.value) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.name < $1.name }
            .prefix(5)
            .map { $0 }
    }

    private var recentRecords: [Record] {
        let weekAgo = Date().addingTimeInterval(-7 * 24 * 60 * 60)
        return records.filter { $0.date >= weekAgo }
    }

    private func save() {
        let stored: [[String: Any]] = records.map {
            ["t": $0.date.timeIntervalSince1970, "k": $0.kind, "a": $0.app]
        }
        defaults.set(stored, forKey: key)
    }
}
