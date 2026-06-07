import AppKit
import Carbon.HIToolbox

/// A thin wrapper over Carbon's `RegisterEventHotKey` — a process-wide hot key
/// that fires even when the app isn't frontmost, with no Accessibility
/// permission required (unlike a CGEvent tap). Used for ⌘, → Settings, since
/// this accessory app has no menu bar to host the standard shortcut.
///
/// The handler is dispatched to the main actor. Hold a strong reference for as
/// long as the shortcut should stay live; deinit unregisters it.
final class HotKey {
    private var ref: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let action: () -> Void

    // A unique id so the global Carbon dispatcher can route events to us.
    private static var nextID: UInt32 = 1
    private let id: UInt32
    private static var registry: [UInt32: HotKey] = [:]

    init?(keyCode: UInt32, modifiers: UInt32, action: @escaping () -> Void) {
        self.action = action
        self.id = HotKey.nextID
        HotKey.nextID += 1

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))

        // Install the shared dispatcher once; it looks the HotKey up by id.
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var hkID = EventHotKeyID()
            GetEventParameter(event,
                              EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID),
                              nil,
                              MemoryLayout<EventHotKeyID>.size,
                              nil,
                              &hkID)
            if let hk = HotKey.registry[hkID.id] {
                DispatchQueue.main.async { hk.action() }
            }
            return noErr
        }, 1, &eventType, nil, &handlerRef)

        let signature: OSType = 0x4E4F5443 // 'NOTC'
        let hotKeyID = EventHotKeyID(signature: signature, id: id)
        let status = RegisterEventHotKey(keyCode,
                                         modifiers,
                                         hotKeyID,
                                         GetApplicationEventTarget(),
                                         0,
                                         &ref)
        guard status == noErr else { return nil }
        HotKey.registry[id] = self
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
        HotKey.registry[id] = nil
    }
}
