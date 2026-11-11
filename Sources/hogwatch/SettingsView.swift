import AppKit
import SwiftUI

/// The alert switches, shared by the Settings window and the welcome window.
struct AlertOptions: View {
    @ObservedObject var settings: Settings

    var body: some View {
        Picker(selection: $settings.cpuThreshold) {
            ForEach(Settings.thresholdChoices, id: \.self) { value in
                Text("\(value)%").tag(value)
            }
        } label: {
            OptionLabel(
                title: "Busy Mac",
                detail: "When total CPU load stays above this level"
            )
        }

        Toggle(isOn: $settings.memoryAlerts) {
            OptionLabel(
                title: "Memory pressure",
                detail: "When macOS reports it is running short of memory"
            )
        }

        Toggle(isOn: $settings.runawayAlerts) {
            OptionLabel(
                title: "Runaway app",
                detail: "When one app keeps a full processor core busy for a minute"
            )
        }

        Toggle(isOn: $settings.batteryAlerts) {
            OptionLabel(
                title: "Battery drain",
                detail: "On battery, when one app keeps half a core busy for a minute"
            )
        }
    }
}

struct OptionLabel: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// "Open at login" switch. Reads and writes the LaunchAgent file directly.
struct LoginItemToggle: View {
    @State private var enabled = LoginItem.isEnabled

    var body: some View {
        Toggle(isOn: Binding(
            get: { enabled },
            set: { wanted in
                if LoginItem.setEnabled(wanted) {
                    enabled = wanted
                }
            }
        )) {
            OptionLabel(
                title: "Open at login",
                detail: "Start hogwatch in the menu bar when you log in"
            )
        }
    }
}

/// Every Settings tab is the same size, so the window never jumps.
enum SettingsLayout {
    static let size = NSSize(width: 520, height: 440)
}

private extension View {
    func settingsPane() -> some View {
        self
            .formStyle(.grouped)
            .frame(width: SettingsLayout.size.width, height: SettingsLayout.size.height)
    }
}

// MARK: - General

struct GeneralSettingsPane: View {
    @ObservedObject var settings: Settings
    @ObservedObject var diagnostics: Diagnostics
    let showWelcome: () -> Void

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    if Bundle.main.bundlePath.hasSuffix(".app") {
                        Image(nsImage: NSApp.applicationIconImage)
                            .resizable()
                            .frame(width: 56, height: 56)
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text("hogwatch")
                            .font(.title3.weight(.semibold))
                        Text("Version \(Settings.version) · Developed by \(Settings.developerName)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("Using \(diagnostics.selfUsage), averaged over a few minutes")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Spacer()
                    Link("Contact Developer", destination: Settings.contactURL)
                }
                .padding(.vertical, 4)
            }

            Section {
                LoginItemToggle()

                Toggle(isOn: $settings.checkForUpdates) {
                    OptionLabel(
                        title: "Check for updates",
                        detail: "Asks GitHub once a day for the latest version. Nothing about you or your Mac is sent."
                    )
                }
            }

            Section {
                Picker(selection: $settings.menuBarReading) {
                    ForEach(MenuBarReading.allCases, id: \.self) { reading in
                        Text(reading.label).tag(reading)
                    }
                } label: {
                    OptionLabel(
                        title: "Menu bar shows",
                        detail: "The icon alone, or the icon with the Mac's total CPU or memory in use"
                    )
                }

                HStack {
                    Text("Welcome tour")
                    Spacer()
                    Button("Show Again", action: showWelcome)
                }
            }
        }
        .settingsPane()
    }
}

// MARK: - Alerts

struct AlertsSettingsPane: View {
    @ObservedObject var settings: Settings

    private var mutedApps: [(key: String, value: String)] {
        settings.ignoredApps.sorted {
            $0.value.localizedCaseInsensitiveCompare($1.value) == .orderedAscending
        }
    }

    var body: some View {
        Form {
            Section("Show the panel for") {
                AlertOptions(settings: settings)
            }

            Section("Muted apps") {
                if mutedApps.isEmpty {
                    Text("None. When an alert is about one app, choose Mute This App in the panel, or right-click any app in the list.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    ForEach(mutedApps, id: \.key) { item in
                        HStack {
                            Image(systemName: "bell.slash")
                                .foregroundStyle(.secondary)
                            Text(item.value)
                            Spacer()
                            Button("Unmute") {
                                settings.ignoredApps[item.key] = nil
                            }
                        }
                    }
                }
            }
        }
        .settingsPane()
    }
}

// MARK: - Panel

struct PanelSettingsPane: View {
    @ObservedObject var settings: Settings

    var body: some View {
        Form {
            Section {
                Picker(selection: $settings.usageStyle) {
                    ForEach(UsageStyle.allCases, id: \.self) { style in
                        Text(style.label).tag(style)
                    }
                } label: {
                    OptionLabel(
                        title: "Show usage as",
                        detail: "Figures, a bar showing each app's share of the whole Mac, or both"
                    )
                }
                .pickerStyle(.segmented)

                Picker(selection: $settings.panelPosition) {
                    ForEach(PanelPosition.allCases, id: \.self) { position in
                        Text(position.label).tag(position)
                    }
                } label: {
                    OptionLabel(
                        title: "Position",
                        detail: "Where the panel sits along the bottom of the screen"
                    )
                }
                .pickerStyle(.segmented)
            }

            Section {
                Picker(selection: $settings.shortcut) {
                    ForEach(ShortcutChoice.allCases, id: \.self) { choice in
                        Text(choice.label).tag(choice)
                    }
                } label: {
                    OptionLabel(
                        title: "Keyboard shortcut",
                        detail: "Opens or closes the panel from any app. Escape also closes it."
                    )
                }

                Picker(selection: $settings.snoozeMinutes) {
                    ForEach(Settings.snoozeChoices, id: \.self) { minutes in
                        Text(minutes == 60 ? "1 hour" : "\(minutes) minutes").tag(minutes)
                    }
                } label: {
                    OptionLabel(
                        title: "Quiet time after dismissing",
                        detail: "How long alerts stay paused after you close one"
                    )
                }
            }
        }
        .settingsPane()
    }
}

// MARK: - History

struct HistorySettingsPane: View {
    @ObservedObject var history: AlertHistory

    var body: some View {
        Form {
            Section("Alerts in the last 7 days") {
                if history.weekTotal == 0 {
                    Text("No alerts yet. When hogwatch has shown a few, the apps behind them are listed here.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    HStack {
                        Text("Total")
                        Spacer()
                        Text("\(history.weekTotal)")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    ForEach(history.weekTopApps) { entry in
                        HStack {
                            Text(entry.name)
                            Spacer()
                            Text(entry.count == 1 ? "1 alert" : "\(entry.count) alerts")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                }
            }

            if history.weekTotal > 0 {
                Section {
                    HStack {
                        Text("History is kept on this Mac for 30 days.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Clear History") { history.clear() }
                    }
                }
            }
        }
        .settingsPane()
    }
}
