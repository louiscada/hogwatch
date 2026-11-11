import AppKit
import SwiftUI

/// Three-page welcome shown the first time hogwatch runs.
struct OnboardingView: View {
    @ObservedObject var settings: Settings
    let finish: () -> Void

    @State private var page = 0
    private let pageCount = 3

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch page {
                case 0: welcome
                case 1: howItWorks
                default: chooseAlerts
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

            Divider()

            HStack {
                HStack(spacing: 6) {
                    ForEach(0..<pageCount, id: \.self) { index in
                        Circle()
                            .fill(index == page ? Color.accentColor : Color.secondary.opacity(0.3))
                            .frame(width: 7, height: 7)
                    }
                }

                Spacer()

                if page > 0 {
                    Button("Back") { page -= 1 }
                }
                Button(page == pageCount - 1 ? "Show Me the Panel" : "Continue") {
                    if page == pageCount - 1 {
                        finish()
                    } else {
                        page += 1
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(width: 500, height: 620)
        .animation(.easeInOut(duration: 0.2), value: page)
    }

    // MARK: - Pages

    private var welcome: some View {
        VStack(spacing: 22) {
            PageHeader(
                symbol: "waveform.path.ecg",
                showsAppIcon: true,
                title: "Welcome to hogwatch",
                subtitle: "It lives in your menu bar and stays out of the way until your Mac is struggling."
            )

            VStack(alignment: .leading, spacing: 16) {
                FeatureRow(
                    symbol: "waveform.path.ecg",
                    title: "Watches quietly",
                    detail: "Checks CPU, memory pressure and battery drain every two seconds."
                )
                FeatureRow(
                    symbol: "rectangle.bottomthird.inset.filled",
                    title: "Speaks up only when needed",
                    detail: "A small panel slides up from the bottom of the screen naming the apps responsible."
                )
                FeatureRow(
                    symbol: "xmark.circle",
                    title: "Lets you act on the spot",
                    detail: "Quit the app that is slowing you down without opening Activity Monitor."
                )
            }
            .padding(.horizontal, 44)

            Spacer(minLength: 0)

            Text("Developed by \(Settings.developerName)")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .padding(.bottom, 12)
        }
        .padding(.top, 34)
    }

    private var howItWorks: some View {
        VStack(spacing: 22) {
            PageHeader(
                symbol: "hand.tap",
                title: "How the panel works",
                subtitle: "Each app in the list has one button. It always starts with the safe option."
            )

            VStack(alignment: .leading, spacing: 16) {
                FeatureRow(
                    symbol: "1.circle",
                    title: "Quit",
                    detail: "Asks the app to close the normal way, so it can save your work first."
                )
                FeatureRow(
                    symbol: "2.circle",
                    title: "Force Quit",
                    detail: "Appears only if the app is still running. Closes it immediately; unsaved changes are lost."
                )
                FeatureRow(
                    symbol: "lock",
                    title: "Locked rows",
                    detail: "Parts of macOS are listed so you can see them, but they cannot be quit. That keeps you from being logged out by accident."
                )
                FeatureRow(
                    symbol: "bell.slash",
                    title: "Mute and snooze",
                    detail: "Mute an app you expect to be busy and it never triggers an alert. Closing the panel pauses alerts for a few minutes."
                )
            }
            .padding(.horizontal, 44)
        }
        .padding(.top, 34)
    }

    private var chooseAlerts: some View {
        VStack(spacing: 6) {
            PageHeader(
                symbol: "bell.badge",
                title: "Choose your alerts",
                subtitle: "Press Control-Option-H in any app to open the panel. Everything here can be changed later in Settings."
            )
            .padding(.top, 34)

            Form {
                Section {
                    AlertOptions(settings: settings)
                }
                Section {
                    LoginItemToggle()
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
        }
    }
}

private struct PageHeader: View {
    let symbol: String
    var showsAppIcon = false
    let title: String
    let subtitle: String

    var body: some View {
        VStack(spacing: 10) {
            if showsAppIcon, Bundle.main.bundlePath.hasSuffix(".app") {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 80, height: 80)
            } else {
                Image(systemName: symbol)
                    .font(.system(size: 30, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(width: 64, height: 64)
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(Color.accentColor)
                    )
            }

            Text(title)
                .font(.system(size: 22, weight: .bold))

            Text(subtitle)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 50)
        }
    }
}

private struct FeatureRow: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 20))
                .foregroundStyle(Color.accentColor)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
