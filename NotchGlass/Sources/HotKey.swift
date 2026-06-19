import AppKit
import Carbon

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

/// The user-configurable global shortcut that summons (toggles) the notch panel.
/// Persisted in `UserDefaults` as a `keyCode`/`modifiers` pair plus an enabled
/// flag, edited in Settings → General, registered by `AppDelegate`.
///
/// `keyCode` is a virtual key code (Carbon `kVK_*`); `modifiers` are Carbon hot
/// key modifier masks (`cmdKey`/`optionKey`/`controlKey`/`shiftKey`), which is
/// what `RegisterEventHotKey` wants. The default is ⌥Space — easy to reach,
/// rarely taken, and not a system default.
struct SummonHotKey: Equatable {
    var keyCode: UInt32
    var modifiers: UInt32
    /// When false the shortcut isn't registered at all — hover stays the only
    /// way in, for users who don't want a global key grabbing ⌥Space.
    var enabled: Bool

    /// ⌥Space — the shipped default.
    static let defaultConfig = SummonHotKey(
        keyCode: UInt32(kVK_Space),
        modifiers: UInt32(optionKey),
        enabled: true
    )

    private static let keyCodeKey = "summonHotKey.keyCode"
    private static let modifiersKey = "summonHotKey.modifiers"
    private static let enabledKey = "summonHotKey.enabled"

    static var current: SummonHotKey {
        get {
            let defaults = UserDefaults.standard
            // No stored keyCode (object absent) → first run → ship the default.
            guard defaults.object(forKey: keyCodeKey) != nil else { return .defaultConfig }
            let code = UInt32(bitPattern: Int32(defaults.integer(forKey: keyCodeKey)))
            let mods = UInt32(bitPattern: Int32(defaults.integer(forKey: modifiersKey)))
            // `enabled` defaults to true when the flag was never written (e.g. a
            // config saved before the flag existed); only an explicit false disables.
            let enabled = defaults.object(forKey: enabledKey) as? Bool ?? true
            return SummonHotKey(keyCode: code, modifiers: mods, enabled: enabled)
        }
        set {
            let defaults = UserDefaults.standard
            defaults.set(Int(Int32(bitPattern: newValue.keyCode)), forKey: keyCodeKey)
            defaults.set(Int(Int32(bitPattern: newValue.modifiers)), forKey: modifiersKey)
            defaults.set(newValue.enabled, forKey: enabledKey)
        }
    }

    /// A human-readable rendering like `⌥Space` or `⌘⇧K`, for the settings row.
    var displayString: String {
        SummonHotKey.modifierSymbols(modifiers) + SummonHotKey.keyName(keyCode)
    }

    /// Carbon modifier mask → the glyphs macOS users expect, in the canonical
    /// ⌃⌥⇧⌘ order.
    static func modifierSymbols(_ modifiers: UInt32) -> String {
        var s = ""
        if modifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if modifiers & UInt32(optionKey)  != 0 { s += "⌥" }
        if modifiers & UInt32(shiftKey)   != 0 { s += "⇧" }
        if modifiers & UInt32(cmdKey)     != 0 { s += "⌘" }
        return s
    }

    /// Translate a Cocoa modifier-flags set (what `NSEvent` reports while
    /// recording) into the Carbon mask `RegisterEventHotKey` needs.
    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var mods: UInt32 = 0
        if flags.contains(.command) { mods |= UInt32(cmdKey) }
        if flags.contains(.option)  { mods |= UInt32(optionKey) }
        if flags.contains(.control) { mods |= UInt32(controlKey) }
        if flags.contains(.shift)   { mods |= UInt32(shiftKey) }
        return mods
    }

    /// A short printable name for a virtual key code. Covers the special keys a
    /// shortcut commonly lands on; everything else falls back to the uppercased
    /// character the key produces, and an unknown code to "Key".
    static func keyName(_ keyCode: UInt32) -> String {
        switch Int(keyCode) {
        case kVK_Space:        return "Space"
        case kVK_Return:       return "↩"
        case kVK_Tab:          return "⇥"
        case kVK_Escape:       return "⎋"
        case kVK_Delete:       return "⌫"
        case kVK_ForwardDelete: return "⌦"
        case kVK_LeftArrow:    return "←"
        case kVK_RightArrow:   return "→"
        case kVK_UpArrow:      return "↑"
        case kVK_DownArrow:    return "↓"
        case kVK_F1:  return "F1";  case kVK_F2:  return "F2";  case kVK_F3:  return "F3"
        case kVK_F4:  return "F4";  case kVK_F5:  return "F5";  case kVK_F6:  return "F6"
        case kVK_F7:  return "F7";  case kVK_F8:  return "F8";  case kVK_F9:  return "F9"
        case kVK_F10: return "F10"; case kVK_F11: return "F11"; case kVK_F12: return "F12"
        default:
            return printableKeyName(keyCode) ?? "Key"
        }
    }

    /// The character a key produces with no modifiers, uppercased — so the W key
    /// reads as "W", the 5 key as "5". Resolved through the current keyboard
    /// layout so non-US layouts label correctly. `nil` when the key has no
    /// printable output (e.g. a dead modifier), letting the caller fall back.
    private static func printableKeyName(_ keyCode: UInt32) -> String? {
        guard let layoutData = TISGetInputSourceProperty(
            TISCopyCurrentKeyboardLayoutInputSource().takeRetainedValue(),
            kTISPropertyUnicodeKeyLayoutData
        ) else { return nil }
        let layout = unsafeBitCast(layoutData, to: CFData.self)
        guard let keyLayoutPtr = CFDataGetBytePtr(layout) else { return nil }
        var deadKeyState: UInt32 = 0
        var length = 0
        var chars = [UniChar](repeating: 0, count: 4)
        let status = keyLayoutPtr.withMemoryRebound(to: UCKeyboardLayout.self, capacity: 1) { ptr in
            UCKeyTranslate(
                ptr,
                UInt16(keyCode),
                UInt16(kUCKeyActionDisplay),
                0, // no modifiers
                UInt32(LMGetKbdType()),
                OptionBits(kUCKeyTranslateNoDeadKeysBit),
                &deadKeyState,
                chars.count,
                &length,
                &chars
            )
        }
        guard status == noErr, length > 0 else { return nil }
        let result = String(utf16CodeUnits: chars, count: length).uppercased()
        return result.isEmpty ? nil : result
    }
}
