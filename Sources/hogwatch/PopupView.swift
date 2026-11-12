import AppKit
import SwiftUI

/// Liquid Glass (macOS 26 Tahoe and macOS 27 Golden Gate) is used when the
/// app is built with Xcode 26 or later and runs on macOS 26 or later.
/// Older systems get the classic blurred HUD material instead.
enum GlassSupport {
    static var isAvailable: Bool {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) { return true }
        #endif
        return false
    }
}

struct PopupView: View {
    @ObservedObject var model: PopupModel
    @ObservedObject var settings: Settings

    private static let coreCount = Double(max(1, ProcessInfo.processInfo.activeProcessorCount))

    /// The row's share of the whole Mac for the current sort: CPU across
    /// all cores, or memory out of installed RAM. Drives the usage bar.
    private func share(of app: AppUsage) -> Double {
        switch model.sortKey {
        case .cpu:
            return app.cpuPercent / (Self.coreCount * 100)
        case .memory:
            let total = model.system.memoryTotalBytes
            return total > 0 ? Double(app.memoryBytes) / Double(total) : 0
        }
    }

    private static let rowHeight: CGFloat = 52
    private static let cornerRadius: CGFloat = 22

    /// Transparent margin around the glass so its own shadow and rim
    /// highlight are not clipped by the window edge.
    static var outerInset: CGFloat { GlassSupport.isAvailable ? 24 : 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            SortToggle(selection: $model.sortKey)

            VStack(spacing: 0) {
                ForEach(model.rows) { app in
                    AppRow(
                        app: app,
                        sortKey: model.sortKey,
                        style: settings.usageStyle,
                        share: share(of: app),
                        isIgnored: settings.ignoredApps[app.id] != nil,
                        quitRequested: model.quitRequested.contains(app.id),
                        model: model
                    )
                    .frame(height: Self.rowHeight)
                }
            }
            .frame(
                height: Self.rowHeight * CGFloat(Settings.rowCount),
                alignment: .top
            )

            footer
        }
        .padding(18)
        .frame(width: 420)
        .modifier(PanelSurface(cornerRadius: Self.cornerRadius))
        .padding(Self.outerInset)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: symbolName)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(symbolColor)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 5) {
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                        .help(subtitleHelp)

                    // Memory pressure is shown as a mark, not as words: the
                    // words did not fit beside the graph.
                    if model.system.memoryPressure != .normal {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(model.system.memoryPressure == .critical ? Color.red : Color.orange)
                            .help("Memory pressure: \(model.system.memoryPressure.label). macOS is running short of memory.")
                    }
                }
            }
            // The text column takes all the width the fixed-size items
            // (icon, graph, close button) leave over, and is laid out first,
            // so the title is only shortened when it truly does not fit.
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)

            Sparkline(values: model.cpuHistory, color: symbolColor)
                .frame(width: 64, height: 24)
                .help("CPU load over the last minute")

            Button(action: model.onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 14, height: 14)
            }
            .modifier(CloseButtonStyle())
            .help("Dismiss")
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Text(footerNote)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer(minLength: 8)

            // Offered when the alert is about one app: the moment you know
            // whether you want to hear about it again.
            if let app = model.alertApp, app.kind == .app {
                let muted = settings.ignoredApps[app.id] != nil
                Button(muted ? "Unmute" : "Mute This App") {
                    model.onToggleIgnore(app)
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .help(muted
                    ? "Let \(app.name) trigger alerts again"
                    : "Never show an alert about \(app.name). You can undo this in Settings.")
            }

            Button(action: model.onOpenActivityMonitor) {
                HStack(spacing: 3) {
                    Text("Activity Monitor")
                    Image(systemName: "arrow.up.forward")
                }
                .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
            .help("Open Activity Monitor")
        }
    }

    /// One short line of context under the list.
    private var footerNote: String {
        if let app = model.alertApp {
            if settings.ignoredApps[app.id] != nil {
                return "Muted."
            }
            if model.alertCount >= 2 {
                return "\(Formatters.ordinal(model.alertCount)) alert about it this week."
            }
        }
        // A reminder for the first few times the panel is seen.
        if settings.panelOpenCount <= 5 {
            return "Quit lets an app save first. Force Quit does not."
        }
        return ""
    }

    private var title: String {
        switch model.reason {
        case .cpu: return "CPU is running hot"
        case .memory: return "Memory is under pressure"
        case .runaway(let name): return "\(name) is working hard"
        case .battery(let name): return "\(name) is draining battery"
        case .manual: return "Top apps right now"
        }
    }

    /// Whole-Mac totals, or, when the alert is about one app, the rule
    /// that app crossed. The rows show a share of the whole Mac, so the
    /// rule is put the same way: 2 of 10 cores reads as about 20% below.
    private var subtitle: String {
        switch model.reason {
        case .runaway:
            return "Using \(settings.runawayCores) of \(Settings.coreCount) cores for a minute"
        case .battery:
            return "Half a core for a minute, on battery"
        case .cpu, .memory, .manual:
            let cpu = Int(model.system.cpuPercent.rounded())
            let memory = Int(model.system.memoryPercent.rounded())
            return "CPU \(cpu)%  ·  Memory \(memory)%"
        }
    }

    /// The longer version, shown when the pointer rests on the subtitle.
    private var subtitleHelp: String {
        let cpu = Int(model.system.cpuPercent.rounded())
        let memory = Int(model.system.memoryPercent.rounded())
        let totals = "The Mac as a whole: CPU \(cpu)%, memory \(memory)%."
        switch model.reason {
        case .runaway(let name):
            let share = Int((Double(settings.runawayCores) / Double(Settings.coreCount) * 100).rounded())
            return "\(name) has kept at least \(Settings.coreLabel(settings.runawayCores)) busy for over a minute. "
                + "This Mac has \(Settings.coreCount) cores, so that is about \(share)% in the list. "
                + "Change the level in Settings, under Alerts. \(totals)"
        case .battery(let name):
            return "\(name) has kept at least half a core busy for over a minute while on battery. \(totals)"
        case .cpu, .memory, .manual:
            return "CPU and memory in use across the whole Mac"
        }
    }

    private var symbolName: String {
        switch model.reason {
        case .cpu: return "flame.fill"
        case .memory: return "memorychip.fill"
        case .runaway: return "bolt.fill"
        case .battery: return "battery.25"
        case .manual: return "chart.bar.fill"
        }
    }

    private var symbolColor: Color {
        switch model.reason {
        case .cpu, .runaway, .battery: return .orange
        case .memory: return .red
        case .manual: return .accentColor
        }
    }
}

private struct AppRow: View {
    let app: AppUsage
    let sortKey: SortKey
    let style: UsageStyle
    let share: Double
    let isIgnored: Bool
    let quitRequested: Bool
    let model: PopupModel

    @State private var hovering = false

    private static let coreCount = Double(max(1, ProcessInfo.processInfo.activeProcessorCount))

    /// CPU as a share of the whole Mac (all cores), the same scale as the
    /// header and the bar, so the rows add up to the total.
    private var cpuOfMac: Double { app.cpuPercent / Self.coreCount }

    var body: some View {
        HStack(spacing: 10) {
            icon
                .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: style == .text ? 1 : 5) {
                HStack(spacing: 5) {
                    Text(app.name)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if isIgnored {
                        Image(systemName: "bell.slash.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                            .help("Muted: never triggers an alert")
                    }
                }

                usage
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Fixed width, so bars and figures line up whatever the button is.
            action
                .frame(width: 84, alignment: .trailing)
        }
        // The highlight reaches well past the icon and button, and nearly
        // fills the row, so it reads as a selectable card.
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(hovering ? 0.07 : 0))
        )
        .padding(.horizontal, -12)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .overlay {
            if app.kind == .app {
                RightClickMenu(title: ignoreTitle) {
                    model.onToggleIgnore(app)
                }
            }
        }
    }

    private var ignoreTitle: String {
        isIgnored ? "Unmute \(app.name)" : "Mute Alerts for \(app.name)"
    }

    /// The second line of a row, in the style chosen in Settings.
    @ViewBuilder
    private var usage: some View {
                switch style {
                case .text:
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .lineLimit(1)
                        .help(tooltip)
                case .bar:
                    UsageBar(share: share)
                        .help(tooltip)
                case .both:
                    HStack(spacing: 8) {
                        UsageBar(share: share)
                        Text(primaryFigure)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .lineLimit(1)
                            .frame(width: 58, alignment: .trailing)
                    }
                    .help(tooltip)
                }
    }

    @ViewBuilder
    private var icon: some View {
        if let path = app.iconPath {
            Image(nsImage: IconCache.shared.icon(forPath: path))
                .resizable()
        } else {
            Image(systemName: "gearshape.2.fill")
                .font(.system(size: 17))
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var action: some View {
        switch app.kind {
        case .app:
            if quitRequested {
                Button("Force Quit") { model.onForceQuit(app) }
                    .controlSize(.small)
                    .modifier(QuitButtonStyle(confirming: true))
                    .help("\(app.name) has not quit yet. Force it to close; unsaved changes are lost.")
            } else {
                Button("Quit") { model.onQuit(app) }
                    .controlSize(.small)
                    .modifier(QuitButtonStyle(confirming: false))
                    .help("Ask \(app.name) to quit")
            }
        case .restartable:
            Button("Restart") { model.onRestart(app) }
                .controlSize(.small)
                .modifier(QuitButtonStyle(confirming: false))
                .help("macOS relaunches \(app.name) right away")
        case .protected, .system:
            Image(systemName: "lock.fill")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .frame(width: 24)
                .help("Part of macOS. Quitting it could log you out, so it is shown for information only.")
        }
    }

    /// The figure for the current sort only, shown beside the bar.
    private var primaryFigure: String {
        switch sortKey {
        case .cpu: return String(format: "%.1f%%", cpuOfMac)
        case .memory: return Formatters.bytes(app.memoryBytes)
        }
    }

    /// Hover text: the row's figures plus Activity Monitor's version of the
    /// CPU number, which counts one core as 100%.
    private var tooltip: String {
        let perCore = String(format: "%.1f%%", app.cpuPercent)
        return "\(detail)\nActivity Monitor shows this CPU figure as \(perCore), where 100% is one core."
    }

    private var detail: String {
        let cpu = String(format: "%.1f%% CPU", cpuOfMac)
        let memory = Formatters.bytes(app.memoryBytes)
        switch sortKey {
        case .cpu: return "\(cpu)  ·  \(memory)"
        case .memory: return "\(memory)  ·  \(cpu)"
        }
    }
}

/// A right-click (or Control-click) menu for a row.
///
/// SwiftUI's own `.contextMenu` does not open in this panel, because the
/// panel never becomes the active window. This asks AppKit to show the menu
/// directly, which works in any window.
private struct RightClickMenu: NSViewRepresentable {
    let title: String
    let action: () -> Void

    func makeNSView(context: Context) -> RightClickView {
        let view = RightClickView()
        view.title = title
        view.action = action
        return view
    }

    func updateNSView(_ view: RightClickView, context: Context) {
        view.title = title
        view.action = action
    }
}

final class RightClickView: NSView {
    var title = ""
    var action: () -> Void = {}

    /// Only context clicks land on this view. Everything else (ordinary
    /// clicks on the row's button, hovering) passes straight through.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let event = NSApp.currentEvent else { return nil }
        let controlClick = event.type == .leftMouseDown && event.modifierFlags.contains(.control)
        guard event.type == .rightMouseDown || controlClick else { return nil }
        return super.hitTest(point)
    }

    override func rightMouseDown(with event: NSEvent) {
        showMenu(for: event)
    }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) {
            showMenu(for: event)
        } else {
            super.mouseDown(with: event)
        }
    }

    private func showMenu(for event: NSEvent) {
        let menu = NSMenu()
        let item = NSMenuItem(title: title, action: #selector(choose), keyEquivalent: "")
        item.target = self
        item.image = NSImage(systemSymbolName: "bell.slash", accessibilityDescription: nil)
        menu.addItem(item)
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    @objc private func choose() {
        action()
    }
}

/// CPU / Memory switch. Drawn by hand rather than with the system segmented
/// control, which looks greyed out in a panel that never takes focus.
private struct SortToggle: View {
    @Binding var selection: SortKey

    var body: some View {
        HStack(spacing: 2) {
            segment("CPU", .cpu)
            segment("Memory", .memory)
        }
        .padding(2)
        .background(Capsule().fill(Color.primary.opacity(0.08)))
        .animation(.easeInOut(duration: 0.15), value: selection)
    }

    private func segment(_ title: String, _ key: SortKey) -> some View {
        let selected = selection == key
        return Button {
            selection = key
        } label: {
            Text(title)
                .font(.system(size: 12, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? Color.primary : Color.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
                .background(
                    Capsule().fill(selected ? AnyShapeStyle(.background) : AnyShapeStyle(Color.clear))
                )
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// A thin bar showing an app's share of the whole Mac. It turns orange
/// from a quarter of the machine and red from half. It is deliberately not
/// animated: five bars easing on every sample kept the app drawing frames
/// for a fifth of the time the panel was open.
private struct UsageBar: View {
    let share: Double

    private var clamped: CGFloat { CGFloat(max(0, min(1, share))) }

    private var color: Color {
        if share >= 0.5 { return .red }
        if share >= 0.25 { return .orange }
        return .accentColor
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.1))
                Capsule()
                    .fill(color)
                    .frame(width: max(5, proxy.size.width * clamped))
            }
        }
        .frame(height: 5)
    }
}

/// CPU load over the last minute, newest sample at the right edge.
private struct Sparkline: View {
    let values: [Double]
    let color: Color

    var body: some View {
        ZStack {
            SparklineShape(values: values, closed: true)
                .fill(color.opacity(0.18))
            SparklineShape(values: values, closed: false)
                .stroke(color, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
        }
    }
}

private struct SparklineShape: Shape {
    let values: [Double]
    let closed: Bool

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard values.count > 1 else { return path }

        let step = rect.width / CGFloat(Settings.historySamples - 1)
        let firstX = rect.maxX - step * CGFloat(values.count - 1)
        func point(_ index: Int) -> CGPoint {
            let clamped = max(0, min(100, values[index]))
            return CGPoint(
                x: firstX + step * CGFloat(index),
                y: rect.maxY - rect.height * CGFloat(clamped / 100)
            )
        }

        path.move(to: point(0))
        for index in 1..<values.count {
            path.addLine(to: point(index))
        }
        if closed {
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            path.addLine(to: CGPoint(x: firstX, y: rect.maxY))
            path.closeSubpath()
        }
        return path
    }
}

/// The panel's surface: Liquid Glass where available, HUD blur otherwise.
private struct PanelSurface: ViewModifier {
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            content.glassEffect(
                .regular,
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
        } else {
            legacy(content)
        }
        #else
        legacy(content)
        #endif
    }

    private func legacy(_ content: Content) -> some View {
        content
            .background(VisualEffectBackground(cornerRadius: cornerRadius))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
            )
    }
}

/// Capsule glass button; turns into a prominent red one while confirming.
private struct QuitButtonStyle: ViewModifier {
    let confirming: Bool

    func body(content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            if confirming {
                content
                    .buttonStyle(.glassProminent)
                    .buttonBorderShape(.capsule)
                    .tint(.red)
            } else {
                // The label colour is set explicitly: in a panel that never
                // becomes the active window, the default renders grey and
                // the button looks disabled.
                content
                    .buttonStyle(.glass)
                    .buttonBorderShape(.capsule)
                    .foregroundStyle(Color.primary)
            }
        } else {
            legacy(content)
        }
        #else
        legacy(content)
        #endif
    }

    private func legacy(_ content: Content) -> some View {
        content
            .buttonStyle(.bordered)
            .tint(confirming ? .red : nil)
    }
}

/// Round glass close button.
private struct CloseButtonStyle: ViewModifier {
    func body(content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            content
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .controlSize(.small)
        } else {
            content.buttonStyle(.plain)
        }
        #else
        content.buttonStyle(.plain)
        #endif
    }
}

/// Blurred, rounded panel background for macOS 13–15.
private struct VisualEffectBackground: NSViewRepresentable {
    let cornerRadius: CGFloat

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        view.maskImage = Self.maskImage(cornerRadius: cornerRadius)
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}

    private static func maskImage(cornerRadius: CGFloat) -> NSImage {
        let edge = cornerRadius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(
            top: cornerRadius, left: cornerRadius, bottom: cornerRadius, right: cornerRadius
        )
        image.resizingMode = .stretch
        return image
    }
}

@MainActor
final class IconCache {
    static let shared = IconCache()
    private var cache: [String: NSImage] = [:]

    func icon(forPath path: String) -> NSImage {
        if let cached = cache[path] { return cached }
        // Keep the cache small: only rows on screen need icons.
        if cache.count >= 64 { cache.removeAll() }
        let image = NSWorkspace.shared.icon(forFile: path)
        image.size = NSSize(width: 28, height: 28)
        cache[path] = image
        return image
    }
}

enum Formatters {
    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .memory
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.allowsNonnumericFormatting = false // "0 MB", not "Zero KB"
        return formatter
    }()

    static func bytes(_ value: UInt64) -> String {
        byteFormatter.string(fromByteCount: Int64(clamping: value))
    }

    /// 1 → "1st", 2 → "2nd", 11 → "11th", 23 → "23rd".
    static func ordinal(_ number: Int) -> String {
        let lastTwo = number % 100
        let suffix: String
        if (11...13).contains(lastTwo) {
            suffix = "th"
        } else {
            switch number % 10 {
            case 1: suffix = "st"
            case 2: suffix = "nd"
            case 3: suffix = "rd"
            default: suffix = "th"
            }
        }
        return "\(number)\(suffix)"
    }
}
