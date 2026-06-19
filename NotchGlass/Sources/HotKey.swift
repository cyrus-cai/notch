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

/// Fires `action` when the user double-taps a *bare* modifier key (e.g. ⌥⌥),
/// the way Raycast/CleanShot summon on a double-tapped ⌘. Carbon's
/// `RegisterEventHotKey` can't represent a lone modifier, so this watches
/// `flagsChanged` through a global+local `NSEvent` monitor — which, unlike a
/// CGEvent tap, needs no Accessibility permission, only the ability to observe
/// modifier state (granted to ordinary apps).
///
/// A "tap" is the target modifier going down and back up with no *other*
/// modifier held at any point; two taps inside `window` seconds fire the action.
/// Hold a strong reference for as long as it should stay live; deinit removes
/// the monitors.
final class DoubleTapModifierMonitor {
    private let flag: NSEvent.ModifierFlags
    private let action: () -> Void
    private let window: TimeInterval
    private var globalMonitor: Any?
    private var localMonitor: Any?

    /// Timestamp of the last completed tap (a down→up of the lone modifier),
    /// taken from the event's own `timestamp` so it's immune to dispatch jitter.
    private var lastTapTime: TimeInterval?
    /// Whether the target modifier is currently the only one held — set on the
    /// down edge, so the matching up edge knows the tap was "clean".
    private var pendingTap = false

    /// - Parameters:
    ///   - carbonModifier: the modifier to watch, as a Carbon mask (`optionKey`…).
    ///   - window: max seconds between the two taps (default 0.30 — Raycast-ish).
    init(carbonModifier: UInt32, window: TimeInterval = 0.30, action: @escaping () -> Void) {
        self.flag = DoubleTapModifierMonitor.cocoaFlag(forCarbon: carbonModifier)
        self.action = action
        self.window = window

        // Global monitor: catches taps while another app is frontmost. Local
        // monitor: catches them while our own (settings) window has focus —
        // global monitors don't see events delivered to our process.
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handle(event)
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handle(event)
            return event
        }
    }

    deinit {
        if let m = globalMonitor { NSEvent.removeMonitor(m) }
        if let m = localMonitor { NSEvent.removeMonitor(m) }
    }

    /// The four modifiers a double-tap cares about. Caps-lock and fn are
    /// deliberately excluded — otherwise an engaged Caps Lock would sit in every
    /// flag set and the "only the target is held" test could never be true.
    private static let watched: NSEvent.ModifierFlags = [.command, .option, .control, .shift]

    private func handle(_ event: NSEvent) {
        // An unmappable modifier (empty `flag`) can never be the sole one held, so
        // bail — otherwise `active == flag` would match every plain key-up.
        guard !flag.isEmpty else { return }

        let active = event.modifierFlags.intersection(DoubleTapModifierMonitor.watched)
        let onlyTargetHeld = active == flag

        if onlyTargetHeld {
            // Down edge: the target modifier just became the sole one held.
            pendingTap = true
            return
        }

        // Any other transition. We only care about the *release* that completes a
        // clean tap: the target went down alone (pendingTap) and now nothing is
        // held. If some other modifier joined in, the tap is dirty — reset.
        guard pendingTap else { return }
        pendingTap = false
        guard active.isEmpty else {
            lastTapTime = nil // a different modifier intruded; not a clean tap
            return
        }

        let now = event.timestamp
        if let last = lastTapTime, now - last <= window {
            lastTapTime = nil
            action()
        } else {
            lastTapTime = now
        }
    }

    /// Map a Carbon modifier mask to the Cocoa flag `NSEvent` reports. Only the
    /// four real modifiers can be double-tapped; anything else yields an empty
    /// set (never matches), which is the safe no-op.
    private static func cocoaFlag(forCarbon carbon: UInt32) -> NSEvent.ModifierFlags {
        switch carbon {
        case UInt32(cmdKey):     return .command
        case UInt32(optionKey):  return .option
        case UInt32(controlKey): return .control
        case UInt32(shiftKey):   return .shift
        default:                 return []
        }
    }
}

/// The user-configurable global shortcut that summons (toggles) the notch panel.
/// Persisted in `UserDefaults` as a `keyCode`/`modifiers` pair plus an enabled
/// flag, edited in Settings → General, registered by `AppDelegate`.
///
/// `keyCode` is a virtual key code (Carbon `kVK_*`); `modifiers` are Carbon hot
/// key modifier masks (`cmdKey`/`optionKey`/`controlKey`/`shiftKey`), which is
/// what `RegisterEventHotKey` wants.
///
/// There are two flavours of trigger, distinguished by `doubleTapModifier`:
///
/// - **Double-tap a bare modifier** (`doubleTapModifier != 0`) — the shipped
///   default is a double-tap of ⌥. `RegisterEventHotKey` can't see a lone
///   modifier, so this is detected by watching `flagsChanged` (see
///   `DoubleTapModifierMonitor`); `keyCode`/`modifiers` are unused.
/// - **A chord** (`doubleTapModifier == 0`) — e.g. ⌥Space or ⌘⇧K, recorded in
///   Settings and registered through Carbon. The original mechanism.
struct SummonHotKey: Equatable {
    var keyCode: UInt32
    var modifiers: UInt32
    /// Non-zero ⇒ this shortcut is a double-tap of a *bare* modifier, and the
    /// value is that modifier's Carbon mask (e.g. `optionKey`). Zero ⇒ it's a
    /// Carbon chord described by `keyCode`/`modifiers`.
    var doubleTapModifier: UInt32 = 0
    /// When false the shortcut isn't registered at all — hover stays the only
    /// way in, for users who don't want a global key grabbing the summon.
    var enabled: Bool

    /// Whether this config triggers on a double-tapped bare modifier.
    var isDoubleTap: Bool { doubleTapModifier != 0 }

    /// Double-tap ⌥ — the shipped default. Reachable one-handed, taken by no
    /// system shortcut, and never collides with a typed character.
    static let defaultConfig = SummonHotKey(
        keyCode: 0,
        modifiers: 0,
        doubleTapModifier: UInt32(optionKey),
        enabled: true
    )

    private static let keyCodeKey = "summonHotKey.keyCode"
    private static let modifiersKey = "summonHotKey.modifiers"
    private static let doubleTapKey = "summonHotKey.doubleTapModifier"
    private static let enabledKey = "summonHotKey.enabled"

    static var current: SummonHotKey {
        get {
            let defaults = UserDefaults.standard
            // No stored config at all (neither a recorded chord nor a double-tap
            // choice) → first run → ship the default (double-tap ⌥).
            guard defaults.object(forKey: keyCodeKey) != nil
                    || defaults.object(forKey: doubleTapKey) != nil else {
                return .defaultConfig
            }
            let code = UInt32(bitPattern: Int32(defaults.integer(forKey: keyCodeKey)))
            let mods = UInt32(bitPattern: Int32(defaults.integer(forKey: modifiersKey)))
            let dbl = UInt32(bitPattern: Int32(defaults.integer(forKey: doubleTapKey)))
            // `enabled` defaults to true when the flag was never written (e.g. a
            // config saved before the flag existed); only an explicit false disables.
            let enabled = defaults.object(forKey: enabledKey) as? Bool ?? true
            return SummonHotKey(keyCode: code, modifiers: mods,
                                doubleTapModifier: dbl, enabled: enabled)
        }
        set {
            let defaults = UserDefaults.standard
            defaults.set(Int(Int32(bitPattern: newValue.keyCode)), forKey: keyCodeKey)
            defaults.set(Int(Int32(bitPattern: newValue.modifiers)), forKey: modifiersKey)
            defaults.set(Int(Int32(bitPattern: newValue.doubleTapModifier)), forKey: doubleTapKey)
            defaults.set(newValue.enabled, forKey: enabledKey)
        }
    }

    /// A human-readable rendering for the settings row: a double-tapped modifier
    /// shows the glyph twice (e.g. `⌥⌥`); a chord shows modifiers + key (`⌘⇧K`).
    var displayString: String {
        if isDoubleTap {
            let glyph = SummonHotKey.modifierSymbols(doubleTapModifier)
            return glyph + glyph
        }
        return SummonHotKey.modifierSymbols(modifiers) + SummonHotKey.keyName(keyCode)
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
