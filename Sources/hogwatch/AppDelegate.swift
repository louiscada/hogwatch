import AppKit
import Combine
import Darwin

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let showOnLaunch: Bool
    private let settings = Settings()
    private let systemSampler = SystemSampler()
    private let processSampler = ProcessSampler()
    private let model = PopupModel()
    private let coreCount = Double(max(1, ProcessInfo.processInfo.activeProcessorCount))

    /// Created the first time the panel is needed, so an idle hogwatch
    /// never loads the panel's UI at all.
    private var popup: PopupPanelController?
    private var statusItem: NSStatusItem!
    private var timer: Timer?

    private let statsItem = NSMenuItem(title: "Measuring…", action: nil, keyEquivalent: "")
    private let pauseItem = NSMenuItem(title: "Pause Alerts for 1 Hour", action: nil, keyEquivalent: "")
    private let history = AlertHistory()
    private let hotKey = HotKey()
    private let updateChecker = UpdateChecker()
    private let updateItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private var shortcutObserver: AnyCancellable?
    private let diagnostics = Diagnostics()
    private lazy var windows = WindowCoordinator(
        settings: settings, history: history, diagnostics: diagnostics
    )

    // Latest sample, kept so the panel can be filled the moment it opens.
    private var latestSystem = SystemSnapshot()
    private var latestApps: [AppUsage] = []
    private var cpuHistory: [Double] = []

    private var tickCount = 0
    private var onBattery = false
    private var cpuHotSamples = 0
    private var memoryHotSamples = 0
    private var calmSamples = 0
    private var busySince: [String: Date] = [:]
    private var busyApp: AppUsage?
    private var ignoredCPU = 0.0
    private var menuBarReading = ""
    private var shownManually = false
    /// Alerts stay away until this time: set by dismissing an alert
    /// (a short snooze) or by "Pause Alerts for 1 Hour".
    private var quietUntil = Date.distantPast

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()

    private var isPopupVisible: Bool { popup?.isVisible ?? false }

    init(showOnLaunch: Bool) {
        self.showOnLaunch = showOnLaunch
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        model.onQuit = { [weak self] app in self?.quit(app) }
        model.onForceQuit = { [weak self] app in self?.forceQuit(app) }
        model.onRestart = { [weak self] app in self?.restart(app) }
        model.onOpenActivityMonitor = { [weak self] in self?.openActivityMonitor() }
        model.onDismiss = { [weak self] in self?.dismiss() }
        model.onToggleIgnore = { [weak self] app in self?.toggleIgnore(app) }

        updateChecker.onChange = { [weak self] version in self?.showUpdate(version) }
        if settings.checkForUpdates {
            showUpdate(updateChecker.knownNewerVersion)
        }

        hotKey.onPressed = { [weak self] in self?.togglePanel() }
        // Fires once now with the saved choice, then again on every change.
        shortcutObserver = settings.$shortcut.sink { [weak self] choice in
            self?.hotKey.apply(choice)
        }

        buildStatusItem()

        windows.onOnboardingFinished = { [weak self] in
            self?.settings.hasOnboarded = true
            self?.showNow()
        }
        if !settings.hasOnboarded {
            windows.showOnboarding()
        }

        // Prime the samplers so the first real tick has a baseline to diff against.
        _ = systemSampler.sample()
        _ = processSampler.sample()

        let timer = Timer(
            timeInterval: Settings.sampleInterval,
            target: self,
            selector: #selector(tick),
            userInfo: nil,
            repeats: true
        )
        timer.tolerance = 0.4
        // .common keeps sampling while a menu is open.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer

        if showOnLaunch {
            perform(#selector(showNow), with: nil, afterDelay: Settings.sampleInterval + 0.5)
        }
    }

    // MARK: - Sampling and alert logic

    @objc private func tick() {
        tickCount += 1
        if tickCount % 5 == 1 {
            onBattery = PowerSource.isOnBattery()
        }
        // Once a minute, see whether the daily update check is due.
        if tickCount % 30 == 0 {
            if settings.checkForUpdates {
                updateChecker.checkIfDue()
            } else if !updateItem.isHidden {
                updateItem.isHidden = true
            }
        }

        // The whole-Mac reading is cheap and runs on every tick.
        let system = systemSampler.sample()
        let ignored = settings.ignoredApps
        let batteryMode = onBattery && settings.batteryAlerts

        // The per-process sample is the costly part. It runs on every tick
        // while the panel is open or the Mac is getting busy, and only on
        // every third tick while things are calm.
        let gettingBusy = system.cpuPercent >= Double(settings.cpuThreshold) - Settings.calmMargin
            || system.memoryPressure != .normal
        let sampleProcesses = isPopupVisible || gettingBusy || latestApps.isEmpty
            || tickCount % Settings.calmProcessSampleEvery == 0

        if sampleProcesses {
            var apps = processSampler.sample()

            // How much of the load comes from apps the user muted.
            ignoredCPU = 0
            if !ignored.isEmpty {
                for app in apps where ignored[app.id] != nil {
                    ignoredCPU += app.cpuPercent
                }
            }
            apps.append(systemRow(system: system, userApps: apps))
            latestApps = apps

            // A single app that has been busy for a full minute.
            let busyLimit: Double? = batteryMode
                ? Settings.batteryCPU
                : (settings.runawayAlerts ? Settings.runawayCPU : nil)
            if let busyLimit = busyLimit {
                busyApp = longRunningBusyApp(in: apps, limit: busyLimit, ignoring: ignored)
            } else {
                busyApp = nil
            }
        }
        let apps = latestApps

        latestSystem = system
        cpuHistory.append(system.cpuPercent)
        if cpuHistory.count > Settings.historySamples {
            cpuHistory.removeFirst(cpuHistory.count - Settings.historySamples)
        }
        updateStatus(system)

        // Whole-machine CPU. Not counted as hot when ignored apps account
        // for more than half of everything in use.
        let totalCPU = system.cpuPercent * coreCount
        let mostlyIgnored = ignoredCPU > totalCPU * 0.5
        let cpuHot = system.cpuPercent >= Double(settings.cpuThreshold) && !mostlyIgnored
        cpuHotSamples = cpuHot ? cpuHotSamples + 1 : 0

        // Memory pressure.
        let memoryTight = settings.memoryAlerts && system.memoryPressure != .normal
        memoryHotSamples = memoryTight ? memoryHotSamples + 1 : 0

        let cpuAlert = cpuHotSamples >= Settings.cpuSustainSamples
        let memoryAlert = memoryHotSamples >= Settings.memorySustainSamples

        if cpuAlert || memoryAlert || busyApp != nil {
            calmSamples = 0
            let now = Date()
            if !isPopupVisible, now >= quietUntil {
                shownManually = false
                model.alertApp = nil
                model.alertCount = 0
                if cpuAlert {
                    model.reason = .cpu
                    model.sortKey = .cpu
                    history.record(kind: "cpu", app: topApp(in: apps, by: .cpu))
                } else if memoryAlert {
                    model.reason = .memory
                    model.sortKey = .memory
                    history.record(kind: "memory", app: topApp(in: apps, by: .memory))
                } else if let app = busyApp {
                    let draining = batteryMode
                        && (app.cpuPercent < Settings.runawayCPU || !settings.runawayAlerts)
                    model.reason = draining ? .battery(app.name) : .runaway(app.name)
                    model.sortKey = .cpu
                    history.record(kind: draining ? "battery" : "runaway", app: app.name)
                    model.alertApp = app
                    model.alertCount = history.weekCount(forApp: app.name)
                }
                publish()
                showPopup(takingKeyboard: false)
                return
            }
        } else if isPopupVisible, !shownManually {
            calmSamples += 1
            if calmSamples >= Settings.calmSamplesBeforeHide {
                popup?.hide()
            }
        }

        // The panel's model is only touched while it is on screen.
        if isPopupVisible {
            publish()
        }
    }

    /// The quittable app using the most of a resource, for the alert history.
    private func topApp(in apps: [AppUsage], by key: SortKey) -> String {
        var best: AppUsage?
        for app in apps where app.kind == .app {
            guard let current = best else {
                best = app
                continue
            }
            switch key {
            case .cpu:
                if app.cpuPercent > current.cpuPercent { best = app }
            case .memory:
                if app.memoryBytes > current.memoryBytes { best = app }
            }
        }
        return best?.name ?? ""
    }

    /// Everything that does not run under your account (kernel_task,
    /// WindowServer, daemons), as one row, so the panel can say when macOS
    /// itself is the busy one.
    private func systemRow(system: SystemSnapshot, userApps: [AppUsage]) -> AppUsage {
        var userCPU = 0.0
        for app in userApps {
            userCPU += app.cpuPercent
        }
        let totalCPU = system.cpuPercent * coreCount
        return AppUsage(
            id: "system",
            name: "macOS and system services",
            iconPath: nil,
            pids: [],
            cpuPercent: max(0, totalCPU - userCPU),
            // Wired memory: what the kernel itself holds. Subtracting apps
            // from "memory used" does not work, because app figures include
            // memory that has been compressed or swapped out.
            memoryBytes: system.memoryWiredBytes,
            kind: .system
        )
    }

    /// Tracks how long each quittable app has been above `limit` and returns
    /// the busiest one that has stayed there for the full window.
    private func longRunningBusyApp(
        in apps: [AppUsage], limit: Double, ignoring ignored: [String: String]
    ) -> AppUsage? {
        let now = Date()
        var next: [String: Date] = [:]
        var busiest: AppUsage?
        for app in apps where app.kind == .app && app.cpuPercent >= limit && ignored[app.id] == nil {
            let since = busySince[app.id] ?? now
            next[app.id] = since
            if now.timeIntervalSince(since) >= Settings.runawaySeconds,
               app.cpuPercent > (busiest?.cpuPercent ?? 0) {
                busiest = app
            }
        }
        busySince = next
        return busiest
    }

    private func publish() {
        model.update(system: latestSystem, apps: latestApps, cpuHistory: cpuHistory)
    }

    private func showPopup(takingKeyboard: Bool) {
        if popup == nil {
            let controller = PopupPanelController(model: model, settings: settings)
            controller.onEscape = { [weak self] in self?.closeWithoutSnoozing() }
            // Clicking elsewhere closes the panel the same way its close
            // button does: an alert is snoozed, a panel you opened is not.
            controller.onOutsideClick = { [weak self] in self?.dismiss() }
            popup = controller
        }
        if settings.panelOpenCount < 100 {
            settings.panelOpenCount += 1
        }
        popup?.show(takingKeyboard: takingKeyboard)
    }

    /// The panel's close button. Dismissing an alert starts a short snooze.
    private func dismiss() {
        if !shownManually {
            let snooze = Date().addingTimeInterval(TimeInterval(settings.snoozeMinutes * 60))
            quietUntil = max(quietUntil, snooze)
            refreshPauseItem()
        }
        shownManually = false
        popup?.hide()
    }

    /// Escape and the keyboard shortcut close the panel without snoozing.
    private func closeWithoutSnoozing() {
        shownManually = true
        dismiss()
    }

    /// The keyboard shortcut: opens the panel, or closes it if it is open.
    private func togglePanel() {
        if isPopupVisible {
            closeWithoutSnoozing()
        } else {
            showNow()
        }
    }

    /// "Never Alert About …" in a row's right-click menu, and its reverse.
    private func toggleIgnore(_ app: AppUsage) {
        guard app.kind == .app else { return }
        if settings.ignoredApps[app.id] != nil {
            settings.ignoredApps[app.id] = nil
        } else {
            settings.ignoredApps[app.id] = app.name
            busySince[app.id] = nil
        }
    }

    // MARK: - Actions on apps

    /// Asks the app to quit the normal way, so it can save or prompt first.
    private func quit(_ app: AppUsage) {
        guard app.kind == .app else { return }
        model.markQuitRequested(app.id)

        var asked = false
        for pid in app.pids {
            if let running = NSRunningApplication(processIdentifier: pid),
               running.activationPolicy != .prohibited {
                asked = running.terminate() || asked
            }
        }
        // Not a regular app (a command-line tool, a script): send SIGTERM instead.
        if !asked {
            for pid in app.pids {
                kill(pid, SIGTERM)
            }
        }
    }

    private func forceQuit(_ app: AppUsage) {
        guard app.kind == .app else { return }
        for pid in app.pids {
            kill(pid, SIGKILL)
        }
        model.remove(app.id)
    }

    /// Finder and the Dock are relaunched by macOS as soon as they exit.
    private func restart(_ app: AppUsage) {
        guard app.kind == .restartable else { return }
        for pid in app.pids {
            kill(pid, SIGTERM)
        }
    }

    private func openActivityMonitor() {
        let url = URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app")
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    // MARK: - Menu bar

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = Self.menuBarGlyph()
            button.imagePosition = .imageLeading
            button.font = NSFont.monospacedDigitSystemFont(
                ofSize: NSFont.systemFontSize(for: .small), weight: .regular
            )
        }

        let menu = NSMenu()
        menu.autoenablesItems = false

        statsItem.isEnabled = false
        menu.addItem(statsItem)
        menu.addItem(.separator())

        menu.addItem(menuItem("Show Top Apps Now", symbol: "rectangle.bottomthird.inset.filled", action: #selector(showNow)))
        menu.addItem(menuItem("Open Activity Monitor", symbol: "waveform.path.ecg", action: #selector(openActivityMonitorFromMenu)))
        menu.addItem(.separator())

        pauseItem.target = self
        pauseItem.action = #selector(togglePause)
        pauseItem.image = NSImage(systemSymbolName: "bell.slash", accessibilityDescription: nil)
        menu.addItem(pauseItem)

        menu.addItem(menuItem("Settings…", symbol: "gearshape", action: #selector(openSettings), key: ","))

        updateItem.target = self
        updateItem.action = #selector(openReleasePage)
        updateItem.image = NSImage(systemSymbolName: "arrow.down.circle", accessibilityDescription: nil)
        updateItem.isHidden = true
        menu.addItem(updateItem)
        menu.addItem(.separator())

        menu.addItem(menuItem("About hogwatch", symbol: "info.circle", action: #selector(showAbout)))
        menu.addItem(menuItem("Quit hogwatch", symbol: "power", action: #selector(quitHogwatch), key: "q"))

        statusItem.menu = menu
    }

    private func menuItem(_ title: String, symbol: String, action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        return item
    }

    /// The app icon's mark, an H whose crossbar is an activity spike, drawn
    /// as a template image so macOS tints it for light and dark menu bars.
    private static func menuBarGlyph() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            NSColor.black.setStroke()

            let pillars = NSBezierPath()
            pillars.lineWidth = 2.6
            pillars.lineCapStyle = .round
            pillars.move(to: NSPoint(x: 4.5, y: 3.5))
            pillars.line(to: NSPoint(x: 4.5, y: 14.5))
            pillars.move(to: NSPoint(x: 13.5, y: 3.5))
            pillars.line(to: NSPoint(x: 13.5, y: 14.5))
            pillars.stroke()

            let pulse = NSBezierPath()
            pulse.lineWidth = 1.3
            pulse.lineCapStyle = .round
            pulse.lineJoinStyle = .round
            pulse.move(to: NSPoint(x: 4.5, y: 9))
            pulse.line(to: NSPoint(x: 6.9, y: 9))
            pulse.line(to: NSPoint(x: 8.1, y: 12))
            pulse.line(to: NSPoint(x: 9.9, y: 6))
            pulse.line(to: NSPoint(x: 11.1, y: 9))
            pulse.line(to: NSPoint(x: 13.5, y: 9))
            pulse.stroke()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "hogwatch"
        return image
    }

    private func updateStatus(_ system: SystemSnapshot) {
        let cpu = Int(system.cpuPercent.rounded())
        let memory = Int(system.memoryPercent.rounded())
        var title = "CPU \(cpu)%   Memory \(memory)%"
        if system.memoryPressure != .normal {
            title += "   Pressure \(system.memoryPressure.label)"
        }
        if statsItem.title != title {
            statsItem.title = title
        }

        // hogwatch's own cost, shown in Settings.
        let ownCPU = processSampler.ownCPUPercent / coreCount
        let ownMemory = Formatters.bytes(processSampler.ownMemoryBytes)
        let selfUsage = String(format: "%.2f%% CPU and %@", ownCPU, ownMemory)
        if diagnostics.selfUsage != selfUsage {
            diagnostics.selfUsage = selfUsage
        }

        // Optional live reading next to the menu bar icon.
        let reading: String
        switch settings.menuBarReading {
        case .none: reading = ""
        case .cpu: reading = " \(cpu)%"
        case .memory: reading = " \(memory)%"
        }
        if reading != menuBarReading {
            menuBarReading = reading
            statusItem.button?.title = reading
        }

        refreshPauseItem()
    }

    /// Makes a snooze or pause visible: the menu says until when, and the
    /// menu bar icon dims while alerts are held back.
    private func refreshPauseItem() {
        let quiet = Date() < quietUntil
        let title = quiet
            ? "Resume Alerts (Paused Until \(Self.timeFormatter.string(from: quietUntil)))"
            : "Pause Alerts for 1 Hour"
        if pauseItem.title != title {
            pauseItem.title = title
            pauseItem.image = NSImage(
                systemSymbolName: quiet ? "bell" : "bell.slash", accessibilityDescription: nil
            )
        }
        if let button = statusItem.button, button.appearsDisabled != quiet {
            button.appearsDisabled = quiet
        }
    }

    @objc private func showNow() {
        shownManually = true
        model.reason = .manual
        model.alertApp = nil
        model.alertCount = 0
        publish()
        if !isPopupVisible {
            showPopup(takingKeyboard: true)
        }
    }

    @objc private func openActivityMonitorFromMenu() {
        openActivityMonitor()
    }

    /// Shows or hides the "Version … Available" line in the menu.
    private func showUpdate(_ version: String?) {
        if let version = version, settings.checkForUpdates {
            updateItem.title = "Version \(version) Available…"
            updateItem.isHidden = false
        } else {
            updateItem.isHidden = true
        }
    }

    @objc private func openReleasePage() {
        NSWorkspace.shared.open(UpdateChecker.releasePage)
    }

    @objc private func openSettings() {
        windows.showSettings()
    }

    @objc private func togglePause() {
        if Date() < quietUntil {
            quietUntil = .distantPast
        } else {
            quietUntil = Date().addingTimeInterval(60 * 60)
            if isPopupVisible, !shownManually {
                popup?.hide()
            }
        }
        refreshPauseItem()
    }

    /// The standard Mac About panel.
    @objc private func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        let plain: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let credits = NSMutableAttributedString(
            string: "A menu bar app that shows what is slowing your Mac down.\nDeveloped by ",
            attributes: plain
        )
        // The developer's name is a link to their profile.
        var linked = plain
        linked[.link] = Settings.profileURL
        credits.append(NSAttributedString(string: Settings.developerName, attributes: linked))
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "hogwatch",
            .applicationVersion: Settings.version,
            .version: "",
            .credits: credits,
        ])
    }

    @objc private func quitHogwatch() {
        NSApp.terminate(nil)
    }
}
