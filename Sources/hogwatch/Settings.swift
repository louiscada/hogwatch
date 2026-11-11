import Combine
import Foundation

/// How each row in the panel shows what an app is using.
enum UsageStyle: String, CaseIterable {
    /// "212.4% CPU · 3.5 GB"
    case text
    /// A bar showing the app's share of the whole Mac.
    case bar
    /// The bar with the figure beside it.
    case both

    var label: String {
        switch self {
        case .text: return "Text"
        case .bar: return "Bar"
        case .both: return "Both"
        }
    }
}

/// Where the panel sits along the bottom of the screen.
enum PanelPosition: String, CaseIterable {
    case left
    case center
    case right

    var label: String {
        switch self {
        case .left: return "Left"
        case .center: return "Centre"
        case .right: return "Right"
        }
    }
}

/// What, if anything, is shown next to the menu bar icon.
enum MenuBarReading: String, CaseIterable {
    case none
    case cpu
    case memory

    var label: String {
        switch self {
        case .none: return "Icon only"
        case .cpu: return "CPU"
        case .memory: return "Memory"
        }
    }
}

/// Live figures about hogwatch itself, shown in Settings.
final class Diagnostics: ObservableObject {
    @Published var selfUsage = "Measuring…"
}

/// User-adjustable settings (persisted in UserDefaults) and tuning constants.
final class Settings: ObservableObject {
    static let version = "0.1.0"

    /// Shown in Settings, the welcome window and --help.
    static let developerName = "louiscada"
    /// Where "Contact Developer" leads. Change this one line to use a
    /// different page or a mailto: address.
    static let contactURL = URL(string: "https://github.com/louiscada/hogwatch/issues")!

    // MARK: Tuning constants

    static let thresholdChoices = [60, 70, 80, 85, 90, 95]
    static let snoozeChoices = [5, 15, 30, 60]

    /// Seconds between samples.
    static let sampleInterval: TimeInterval = 2

    /// Whole-machine CPU must stay above the threshold for this many samples
    /// in a row before the panel appears (avoids popping up on brief spikes).
    static let cpuSustainSamples = 3

    /// Memory pressure must stay elevated for this many samples in a row.
    static let memorySustainSamples = 2

    /// A single app using at least this much CPU (100 = one full core)…
    static let runawayCPU = 100.0
    /// …or this much while on battery…
    static let batteryCPU = 50.0
    /// …for this long is flagged on its own,
    /// even when the machine as a whole is not busy.
    static let runawaySeconds: TimeInterval = 60

    /// While the Mac is calm and the panel is closed, the per-process sample
    /// (the costly part) runs only on every this-many ticks. The cheap
    /// whole-Mac reading still runs on every tick.
    static let calmProcessSampleEvery = 5
    /// "Calm" means total CPU is at least this far below the alert threshold.
    static let calmMargin = 25.0

    /// Samples below every threshold before the panel hides itself.
    static let calmSamplesBeforeHide = 5

    /// Rows listed in the panel.
    static let rowCount = 5

    /// Samples kept for the CPU sparkline (60 seconds).
    static let historySamples = 30

    // MARK: User settings

    /// Whole-machine CPU load, in percent, that triggers the panel.
    @Published var cpuThreshold: Int {
        didSet { defaults.set(cpuThreshold, forKey: Key.cpuThreshold) }
    }
    /// Alert when macOS reports memory pressure.
    @Published var memoryAlerts: Bool {
        didSet { defaults.set(memoryAlerts, forKey: Key.memoryAlerts) }
    }
    /// Alert when one app holds a full core for a minute.
    @Published var runawayAlerts: Bool {
        didSet { defaults.set(runawayAlerts, forKey: Key.runawayAlerts) }
    }
    /// On battery, alert when one app holds half a core for a minute.
    @Published var batteryAlerts: Bool {
        didSet { defaults.set(batteryAlerts, forKey: Key.batteryAlerts) }
    }
    /// Minutes the panel stays away after you dismiss it.
    @Published var snoozeMinutes: Int {
        didSet { defaults.set(snoozeMinutes, forKey: Key.snoozeMinutes) }
    }
    /// Apps that never trigger an alert: bundle path (or process id key) → name.
    @Published var ignoredApps: [String: String] {
        didSet { defaults.set(ignoredApps, forKey: Key.ignoredApps) }
    }
    /// Where the panel sits along the bottom of the screen.
    @Published var panelPosition: PanelPosition {
        didSet { defaults.set(panelPosition.rawValue, forKey: Key.panelPosition) }
    }
    /// A live figure shown next to the menu bar icon.
    @Published var menuBarReading: MenuBarReading {
        didSet { defaults.set(menuBarReading.rawValue, forKey: Key.menuBarReading) }
    }
    /// How many times the panel has been opened; the beginner's hint in the
    /// panel footer is dropped after the first few.
    @Published var panelOpenCount: Int {
        didSet { defaults.set(panelOpenCount, forKey: Key.panelOpenCount) }
    }
    /// Global keyboard shortcut that opens or closes the panel.
    @Published var shortcut: ShortcutChoice {
        didSet { defaults.set(shortcut.rawValue, forKey: Key.shortcut) }
    }
    /// Ask GitHub once a day whether a newer version exists.
    @Published var checkForUpdates: Bool {
        didSet { defaults.set(checkForUpdates, forKey: Key.checkForUpdates) }
    }
    /// How rows in the panel show usage.
    @Published var usageStyle: UsageStyle {
        didSet { defaults.set(usageStyle.rawValue, forKey: Key.usageStyle) }
    }
    /// False until the welcome window has been seen once.
    @Published var hasOnboarded: Bool {
        didSet { defaults.set(hasOnboarded, forKey: Key.hasOnboarded) }
    }

    private enum Key {
        static let cpuThreshold = "cpuThreshold"
        static let memoryAlerts = "memoryAlerts"
        static let runawayAlerts = "runawayAlerts"
        static let batteryAlerts = "batteryAlerts"
        static let snoozeMinutes = "snoozeMinutes"
        static let hasOnboarded = "hasOnboarded"
        static let usageStyle = "usageStyle"
        static let ignoredApps = "ignoredApps"
        static let panelPosition = "panelPosition"
        static let menuBarReading = "menuBarReading"
        static let panelOpenCount = "panelOpenCount"
        static let shortcut = "shortcut"
        static let checkForUpdates = "checkForUpdates"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        func bool(_ key: String, fallback: Bool) -> Bool {
            defaults.object(forKey: key) == nil ? fallback : defaults.bool(forKey: key)
        }
        let cpu = defaults.integer(forKey: Key.cpuThreshold)
        let snooze = defaults.integer(forKey: Key.snoozeMinutes)

        cpuThreshold = Settings.thresholdChoices.contains(cpu) ? cpu : 85
        memoryAlerts = bool(Key.memoryAlerts, fallback: true)
        runawayAlerts = bool(Key.runawayAlerts, fallback: true)
        batteryAlerts = bool(Key.batteryAlerts, fallback: true)
        snoozeMinutes = Settings.snoozeChoices.contains(snooze) ? snooze : 5
        usageStyle = UsageStyle(rawValue: defaults.string(forKey: Key.usageStyle) ?? "") ?? .text
        ignoredApps = defaults.dictionary(forKey: Key.ignoredApps) as? [String: String] ?? [:]
        panelPosition = PanelPosition(rawValue: defaults.string(forKey: Key.panelPosition) ?? "") ?? .center
        menuBarReading = MenuBarReading(rawValue: defaults.string(forKey: Key.menuBarReading) ?? "") ?? .none
        panelOpenCount = defaults.integer(forKey: Key.panelOpenCount)
        checkForUpdates = bool(Key.checkForUpdates, fallback: true)
        shortcut = ShortcutChoice(rawValue: defaults.string(forKey: Key.shortcut) ?? "") ?? .controlOptionH
        hasOnboarded = bool(Key.hasOnboarded, fallback: false)
    }
}
