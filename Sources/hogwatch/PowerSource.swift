import Foundation
import IOKit.ps

enum PowerSource {
    /// True when the Mac is running from its battery rather than a charger.
    static func isOnBattery() -> Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let source = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue()
        else { return false }
        return (source as String) == "Battery Power"
    }
}
