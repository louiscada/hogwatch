import AppKit

@main
enum HogwatchApp {
    @MainActor
    static func main() {
        let arguments = CommandLine.arguments.dropFirst()

        if arguments.contains("--version") || arguments.contains("-v") {
            print("hogwatch \(Settings.version)")
            return
        }

        if arguments.contains("--help") || arguments.contains("-h") {
            print("""
            hogwatch \(Settings.version)
            Watches CPU and memory. When either runs high, a small panel slides up
            from the bottom of the screen listing the apps responsible, with a
            Quit button next to each.

            USAGE
              hogwatch            Run in the menu bar
              hogwatch --demo     Run and show the panel immediately (for testing)
              hogwatch --version  Print the version
              hogwatch --help     Print this help

            Alerts are configured in Settings, from the menu bar icon.

            Developed by \(Settings.developerName)
            Contact: \(Settings.contactURL.absoluteString)
            Profile: \(Settings.profileURL.absoluteString)
            """)
            return
        }

        let app = NSApplication.shared
        // NSApplication holds its delegate weakly; this local keeps it alive
        // for as long as run() does, which is the life of the app.
        let delegate = AppDelegate(showOnLaunch: arguments.contains("--demo"))
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
