import Combine
import Foundation

enum SortKey: Hashable {
    case cpu
    case memory
}

enum AlertReason {
    /// The whole machine is busy.
    case cpu
    /// macOS reports memory pressure.
    case memory
    /// One app has been using a lot of CPU for a while.
    case runaway(String)
    /// One app is working hard while the Mac is on battery.
    case battery(String)
    /// Opened from the menu bar.
    case manual
}

/// State shared between the monitor and the SwiftUI panel.
/// Only written to while the panel is on screen.
final class PopupModel: ObservableObject {
    @Published private(set) var rows: [AppUsage] = []
    @Published private(set) var system = SystemSnapshot()
    @Published private(set) var cpuHistory: [Double] = []
    @Published var reason: AlertReason = .manual
    /// The app an alert is about, when it is about one app in particular.
    @Published var alertApp: AppUsage?
    /// How many alerts that app has caused this week, this one included.
    @Published var alertCount = 0
    @Published var sortKey: SortKey = .cpu {
        didSet { rebuildRows() }
    }
    /// Rows that have been asked to quit and are still running;
    /// their button escalates to Force Quit.
    @Published private(set) var quitRequested: Set<String> = []

    var onQuit: (AppUsage) -> Void = { _ in }
    var onForceQuit: (AppUsage) -> Void = { _ in }
    var onRestart: (AppUsage) -> Void = { _ in }
    var onOpenActivityMonitor: () -> Void = {}
    var onDismiss: () -> Void = {}
    var onToggleIgnore: (AppUsage) -> Void = { _ in }

    private var allApps: [AppUsage] = []

    func update(system: SystemSnapshot, apps: [AppUsage], cpuHistory: [Double]) {
        self.system = system
        self.cpuHistory = cpuHistory
        allApps = apps
        if !quitRequested.isEmpty {
            let stillRunning = quitRequested.intersection(apps.map(\.id))
            if stillRunning != quitRequested { quitRequested = stillRunning }
        }
        rebuildRows()
    }

    func markQuitRequested(_ id: String) {
        quitRequested.insert(id)
    }

    func remove(_ id: String) {
        allApps.removeAll { $0.id == id }
        quitRequested.remove(id)
        rebuildRows()
    }

    private func rebuildRows() {
        let sorted: [AppUsage]
        switch sortKey {
        case .cpu:
            // Compared to one decimal place, with names breaking ties, so
            // near-idle apps do not swap places on every sample.
            sorted = allApps.sorted {
                let left = ($0.cpuPercent * 10).rounded()
                let right = ($1.cpuPercent * 10).rounded()
                return left != right ? left > right : $0.name < $1.name
            }
        case .memory:
            sorted = allApps.sorted {
                $0.memoryBytes != $1.memoryBytes ? $0.memoryBytes > $1.memoryBytes : $0.name < $1.name
            }
        }
        rows = Array(sorted.prefix(Settings.rowCount))
    }
}
