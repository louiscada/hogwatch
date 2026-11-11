import Carbon.HIToolbox
import Foundation

/// The keyboard shortcuts offered in Settings for opening the panel.
enum ShortcutChoice: String, CaseIterable {
    case off
    case controlOptionH
    case controlOptionCommandH
    case optionShiftH

    var label: String {
        switch self {
        case .off: return "Off"
        case .controlOptionH: return "⌃⌥H"
        case .controlOptionCommandH: return "⌃⌥⌘H"
        case .optionShiftH: return "⌥⇧H"
        }
    }

    /// Carbon modifier mask; nil when the shortcut is off.
    fileprivate var modifiers: UInt32? {
        switch self {
        case .off: return nil
        case .controlOptionH: return UInt32(controlKey | optionKey)
        case .controlOptionCommandH: return UInt32(controlKey | optionKey | cmdKey)
        case .optionShiftH: return UInt32(optionKey | shiftKey)
        }
    }
}

/// A system-wide keyboard shortcut. Uses the Carbon hot-key API, which works
/// from any app without asking for Accessibility permission.
final class HotKey {
    var onPressed: () -> Void = {}

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    func apply(_ choice: ShortcutChoice) {
        unregister()
        guard let modifiers = choice.modifiers else { return }
        installHandlerIfNeeded()

        let identifier = EventHotKeyID(signature: OSType(0x4857_4348), id: 1) // "HWCH"
        RegisterEventHotKey(
            UInt32(kVK_ANSI_H), modifiers, identifier,
            GetApplicationEventTarget(), 0, &hotKeyRef
        )
    }

    private func unregister() {
        if let hotKeyRef = hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
        }
        hotKeyRef = nil
    }

    private func installHandlerIfNeeded() {
        guard handlerRef == nil else { return }
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, userData in
                guard let userData = userData else { return noErr }
                Unmanaged<HotKey>.fromOpaque(userData).takeUnretainedValue().onPressed()
                return noErr
            },
            1, &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &handlerRef
        )
    }
}
