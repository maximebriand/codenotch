import AppKit
import Carbon.HIToolbox

/// A keyboard shortcut that works whatever application is in front.
///
/// Carbon's `RegisterEventHotKey` rather than
/// `NSEvent.addGlobalMonitorForEvents`: the monitor route reads *every*
/// keystroke aimed at every other application, and macOS gates it behind the
/// Accessibility permission — a trip to System Settings, a restart, and a
/// dialogue that asks for far more than a shortcut is worth. Registering a hot
/// key asks the window server to deliver one combination and needs no
/// permission at all, which is the whole reason this file is the old API.
///
/// It has no Swift replacement, deprecation notices notwithstanding.
final class GlobalHotKey {
    /// ⌥⌘S — the switcher's default. Not ⌘⇧A or anything in the ⌘⇧ range,
    /// which editors and terminals have already spoken for.
    static let defaultKeyCode = UInt32(kVK_ANSI_S)
    static let defaultModifiers = UInt32(optionKey | cmdKey)

    /// The Carbon handler is a C function pointer and can capture nothing, so
    /// what to run is looked up here by the id the event carries.
    private static var actions: [UInt32: () -> Void] = [:]
    private static var nextID: UInt32 = 1
    private static var handler: EventHandlerRef?
    /// A four-character code identifying this app's hot keys, so an event meant
    /// for someone else's registration is never mistaken for one of ours.
    private static let signature = OSType(0x434E_4348)   // 'CNCH'

    private let identifier: UInt32
    private var reference: EventHotKeyRef?

    /// Nil when the combination is already spoken for by another application —
    /// first registration wins, system-wide, and there is nothing to be done
    /// about it but say so and let the caller offer another.
    init?(keyCode: UInt32, modifiers: UInt32, action: @escaping () -> Void) {
        Self.installHandler()
        identifier = Self.nextID
        Self.nextID += 1

        var reference: EventHotKeyRef?
        let status = RegisterEventHotKey(
            keyCode, modifiers,
            EventHotKeyID(signature: Self.signature, id: identifier),
            GetApplicationEventTarget(), 0, &reference
        )
        guard status == noErr, let reference else {
            Log.usage.notice("hot key \(keyCode, privacy: .public) unavailable: \(status, privacy: .public)")
            return nil
        }
        self.reference = reference
        Self.actions[identifier] = action
    }

    deinit {
        if let reference { UnregisterEventHotKey(reference) }
        let identifier = self.identifier
        // Off the deinit's own thread: the table is only ever touched on the
        // main queue, where the Carbon callback also reads it.
        DispatchQueue.main.async { GlobalHotKey.actions[identifier] = nil }
    }

    /// One handler for the process, installed on first use. Registering a
    /// second would deliver every press twice.
    private static func installHandler() {
        guard handler == nil else { return }
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            guard let event else { return OSStatus(eventNotHandledErr) }
            var pressed = EventHotKeyID()
            let status = GetEventParameter(
                event, EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID), nil,
                MemoryLayout<EventHotKeyID>.size, nil, &pressed
            )
            guard status == noErr, pressed.signature == GlobalHotKey.signature else {
                return OSStatus(eventNotHandledErr)
            }
            // Hopped to the main queue rather than run here: this is the window
            // server's callback, and opening a window from it is not its job.
            DispatchQueue.main.async { GlobalHotKey.actions[pressed.id]?() }
            return noErr
        }, 1, &type, nil, &handler)
    }
}
