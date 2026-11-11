import AppKit
import QuartzCore
import SwiftUI

/// Borderless floating panel that can take clicks without activating the app
/// or stealing focus from whatever you are working in.
final class PopupPanel: NSPanel {
    var onEscape: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    // Escape closes the panel when it has the keyboard.
    override func cancelOperation(_ sender: Any?) {
        onEscape?()
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // Escape
            onEscape?()
        } else {
            super.keyDown(with: event)
        }
    }
}

/// Lets buttons respond to the very first click, even though the panel
/// is not the key window.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Owns the panel and slides it up from / down past the bottom screen edge.
@MainActor
final class PopupPanelController: NSObject {
    private let panel: PopupPanel
    private let panelSize: NSSize
    private let settings: Settings
    private(set) var isVisible = false

    /// Called when Escape is pressed while the panel has the keyboard.
    var onEscape: () -> Void = {}

    /// Called when you click anywhere outside the panel.
    var onOutsideClick: () -> Void = {}

    private var outsideClickMonitor: Any?
    private var ignoreOutsideClicksUntil = Date.distantPast

    private static let bottomMargin: CGFloat = 14
    private static let showDuration: TimeInterval = 0.5
    private static let hideDuration: TimeInterval = 0.3

    init(model: PopupModel, settings: Settings) {
        let hosting = FirstMouseHostingView(rootView: PopupView(model: model, settings: settings))
        panelSize = hosting.fittingSize
        self.settings = settings

        let panel = PopupPanel(
            contentRect: NSRect(origin: .zero, size: panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = hosting
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // Liquid Glass draws its own shadow and rim; the window shadow would double it.
        panel.hasShadow = !GlassSupport.isAvailable
        panel.level = .statusBar
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.animationBehavior = .none
        self.panel = panel
        super.init()
        panel.onEscape = { [weak self] in self?.onEscape() }
    }

    /// - Parameter takingKeyboard: true when you opened the panel yourself
    ///   (menu or shortcut), so Escape can close it. Alerts that appear on
    ///   their own never take the keyboard away from what you are typing in.
    func show(takingKeyboard: Bool = false) {
        guard !isVisible, let screen = targetScreen() else { return }
        NSObject.cancelPreviousPerformRequests(
            withTarget: self, selector: #selector(finishHide), object: nil
        )
        isVisible = true

        // An alert that appears on its own ignores outside clicks for a
        // moment, so a click you were already making cannot dismiss it
        // before you have seen it.
        ignoreOutsideClicksUntil = Date().addingTimeInterval(takingKeyboard ? 0.2 : 1.5)
        startWatchingOutsideClicks()

        let resting = restingFrame(on: screen)
        panel.setFrame(offscreenFrame(below: resting, on: screen), display: false)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        if takingKeyboard {
            panel.makeKey()
        }
        panel.invalidateShadow()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.showDuration
            // Fast start, long soft landing.
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.16, 1.0, 0.3, 1.0)
            panel.animator().setFrame(resting, display: true)
            panel.animator().alphaValue = 1
        }
    }

    func hide() {
        guard isVisible else { return }
        isVisible = false
        stopWatchingOutsideClicks()

        let screen = panel.screen ?? targetScreen()
        var destination = panel.frame
        if let screen = screen {
            destination = offscreenFrame(below: panel.frame, on: screen)
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.hideDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().setFrame(destination, display: true)
            panel.animator().alphaValue = 0
        }
        perform(#selector(finishHide), with: nil, afterDelay: Self.hideDuration + 0.05)
    }

    /// Watches for mouse clicks in other apps and on the desktop. Clicks
    /// inside the panel itself are not reported here.
    private func startWatchingOutsideClicks() {
        guard outsideClickMonitor == nil else { return }
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleOutsideClick()
            }
        }
    }

    private func stopWatchingOutsideClicks() {
        if let monitor = outsideClickMonitor {
            NSEvent.removeMonitor(monitor)
        }
        outsideClickMonitor = nil
    }

    private func handleOutsideClick() {
        guard isVisible, Date() >= ignoreOutsideClicksUntil else { return }
        onOutsideClick()
    }

    @objc private func finishHide() {
        if !isVisible {
            panel.orderOut(nil)
        }
    }

    /// The screen the pointer is on, so the panel appears where you are looking.
    private func targetScreen() -> NSScreen? {
        let pointer = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(pointer) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
    }

    /// Sitting just above the Dock, at the side chosen in Settings.
    private func restingFrame(on screen: NSScreen) -> NSRect {
        let visible = screen.visibleFrame
        let inset = PopupView.outerInset
        let x: CGFloat
        switch settings.panelPosition {
        case .left:
            x = visible.minX + Self.bottomMargin - inset
        case .center:
            x = visible.midX - panelSize.width / 2
        case .right:
            x = visible.maxX - panelSize.width - Self.bottomMargin + inset
        }
        return NSRect(
            x: x.rounded(),
            y: visible.minY + Self.bottomMargin - PopupView.outerInset,
            width: panelSize.width,
            height: panelSize.height
        )
    }

    /// Same horizontal position, fully below the bottom edge of the screen.
    private func offscreenFrame(below frame: NSRect, on screen: NSScreen) -> NSRect {
        var result = frame
        result.origin.y = screen.frame.minY - frame.height - 20
        return result
    }
}
