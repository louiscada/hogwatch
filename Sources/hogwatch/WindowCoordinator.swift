import AppKit
import SwiftUI

/// Owns the Settings and welcome windows. Each is built when first opened
/// and released again when closed, so neither costs anything while unused.
@MainActor
final class WindowCoordinator: NSObject, NSWindowDelegate {
    private let settings: Settings
    private let history: AlertHistory
    private let diagnostics: Diagnostics
    private var settingsWindow: NSWindow?
    private var onboardingWindow: NSWindow?

    /// Called when the welcome window's last button is pressed.
    var onOnboardingFinished: () -> Void = {}

    init(settings: Settings, history: AlertHistory, diagnostics: Diagnostics) {
        self.settings = settings
        self.history = history
        self.diagnostics = diagnostics
        super.init()
    }

    // MARK: - Settings

    /// A standard Mac settings window: tabs in the toolbar, each with an icon.
    func showSettings() {
        if settingsWindow == nil {
            let tabs = NSTabViewController()
            tabs.tabStyle = .toolbar

            let general = GeneralSettingsPane(settings: settings, diagnostics: diagnostics) { [weak self] in
                self?.showOnboarding()
            }
            tabs.addTabViewItem(pane("General", symbol: "gearshape", view: general))
            tabs.addTabViewItem(pane("Alerts", symbol: "bell.badge", view: AlertsSettingsPane(settings: settings)))
            tabs.addTabViewItem(pane("Panel", symbol: "rectangle.bottomthird.inset.filled", view: PanelSettingsPane(settings: settings)))
            tabs.addTabViewItem(pane("History", symbol: "clock.arrow.circlepath", view: HistorySettingsPane(history: history)))

            let window = NSWindow(contentViewController: tabs)
            window.styleMask = [.titled, .closable]
            window.toolbarStyle = .preference
            window.setContentSize(SettingsLayout.size)
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            settingsWindow = window
        }
        present(settingsWindow)
    }

    private func pane<Content: View>(_ title: String, symbol: String, view: Content) -> NSTabViewItem {
        let controller = NSHostingController(rootView: view)
        controller.title = title
        controller.preferredContentSize = SettingsLayout.size

        let item = NSTabViewItem(viewController: controller)
        item.label = title
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        return item
    }

    // MARK: - Welcome

    func showOnboarding() {
        if onboardingWindow == nil {
            let view = OnboardingView(settings: settings) { [weak self] in
                self?.finishOnboarding()
            }
            let hosting = NSHostingView(rootView: view)
            let window = NSWindow(
                contentRect: NSRect(origin: .zero, size: hosting.fittingSize),
                styleMask: [.titled, .closable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            window.contentView = hosting
            window.title = "Welcome to hogwatch"
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.isMovableByWindowBackground = true
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            onboardingWindow = window
        }
        present(onboardingWindow)
    }

    private func finishOnboarding() {
        onboardingWindow?.close()
        onOnboardingFinished()
    }

    private func present(_ window: NSWindow?) {
        // A menu bar app has to bring itself forward for its window to take focus.
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        if window === settingsWindow {
            settingsWindow = nil
        } else if window === onboardingWindow {
            onboardingWindow = nil
            // Closing the welcome early still counts as having seen it.
            if !settings.hasOnboarded {
                settings.hasOnboarded = true
            }
        }
    }
}
