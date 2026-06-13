import AppKit
import Carbon.HIToolbox
import Combine
import SwiftUI

/// Owns the notch panels for the lifetime of the app — one per screen the
/// `DisplayPlacement` setting covers, each pinned to its screen's top-center.
/// All panels share one `NotchModel` (one conversation, one Recent list); the
/// model's `activeDisplay` says which screen's island is unfurled, the rest
/// keep their resting notch.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// The live panels, keyed by `CGDirectDisplayID` so screen plug/unplug and
    /// layout changes diff cleanly against `NSScreen.screens`.
    private var panels: [CGDirectDisplayID: NotchPanel] = [:]
    private let model = NotchModel(ai: AppDelegate.makeService())
    private var openObserver: AnyCancellable?

    /// Pick the live backend for the selected provider when an API key is
    /// available (env var or the stored entry from Settings), otherwise fall
    /// back to the offline stub so the UI still works out of the box.
    private static func makeService() -> AIService {
        let provider = APIKeyStore.selectedProvider
        guard let key = APIKeyStore.current(for: provider) else {
            return StubAIService()
        }
        let model = APIKeyStore.effectiveModel(for: provider)
        // Anthropic speaks its own protocol; everyone else is OpenAI-compatible.
        if provider.isOpenAICompatible {
            return OpenAICompatAIService(provider: provider, apiKey: key, model: model)
        } else {
            return AnthropicAIService(provider: provider, apiKey: key, model: model)
        }
    }

    /// True when a real key is available for the selected provider — i.e. the
    /// backend `makeService` builds is live rather than the offline stub. Drives
    /// the result view's "set up your model" prompt when false.
    private static func isConfigured() -> Bool {
        APIKeyStore.current(for: APIKeyStore.selectedProvider) != nil
    }

    /// Point the model at the right backend AND tell it whether that backend is
    /// live, so both move together. Called at launch and whenever Settings saves a
    /// key / switches providers.
    private func syncService() {
        model.setService(AppDelegate.makeService())
        model.isConfigured = AppDelegate.isConfigured()
    }
    private var settingsHotKey: HotKey?

    /// The panel is wider/taller than the resting notch so the glass has room to
    /// unfurl downward. The SwiftUI view draws the notch at the top-center of
    /// this canvas; the empty area around it is fully transparent and
    /// click-through (see `ContentView`'s hit testing).
    private let canvasWidth: CGFloat = 760
    private let canvasHeight: CGFloat = 640

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Agent app: no Dock icon, no app menu — it's a pure overlay.
        NSApp.setActivationPolicy(.accessory)

        // Seed the configured flag to match the service the model launched with.
        model.isConfigured = AppDelegate.isConfigured()

        // Start sampling mouse movement so a hover-open can read the cursor's
        // approach vector — the entry physics in `NotchIsland` feed on it.
        MouseVelocityTracker.shared.start()

        // Warm the ask/note intent engine off the main thread: fetch/load the
        // embedding model and restore (or fit, first run ~seconds) the per-language
        // classification heads, so the first keystroke classifies in ~10ms instead
        // of paying that cost mid-typing. Background priority — typing that lands
        // before this finishes just reads as unsure → ask default.
        Task.detached(priority: .background) {
            await IntentEngine.shared.prepare()
        }

        // Quiet daily update check, deferred past launch so it never competes
        // with first paint. Result only ever surfaces as the gear dot.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            UpdaterService.shared.checkIfDue()
        }

        rebuildPanels()

        // When the panel opens (on hover), make the active screen's panel the
        // key window so keystrokes land in the prompt field immediately — no
        // extra click needed. Because it's a non-activating panel, this grabs
        // keyboard focus WITHOUT stealing app activation or the menu bar from
        // the frontmost app. Keyed on (open, activeDisplay) together so a
        // display *switch* while open hands the keyboard over with the island.
        // On close, hand key status back so we never hold the keyboard at rest.
        openObserver = model.$open
            .combineLatest(model.$activeDisplay)
            .removeDuplicates(by: ==)
            .sink { [weak self] isOpen, active in
                guard let self else { return }
                if isOpen {
                    // This fires synchronously inside the hover handler ($open
                    // publishes on willSet) — BEFORE SwiftUI commits the open
                    // animation's first frame. The key-window dance does
                    // window-server round trips, so running it inline taxes
                    // that exact frame. Defer one runloop turn: the spring's
                    // first frame renders first, the keyboard handoff lands
                    // right after (still well ahead of NotchBody raising
                    // focus at +0.08s).
                    DispatchQueue.main.async {
                        guard self.model.open else { return }
                        // Debug paths set `open` without claiming a display; fall
                        // back to the preferred screen's panel so they still key.
                        let target = active.flatMap { self.panels[$0] }
                            ?? self.preferredScreen()?.displayID.flatMap { self.panels[$0] }
                            ?? self.panels.values.first
                        for p in self.panels.values where p !== target && p.isKeyWindow {
                            p.resignKey()
                        }
                        target?.makeKeyAndOrderFront(nil)
                        // Long-running agent: piggyback the daily update check on
                        // panel opens so it still happens without relaunches.
                        UpdaterService.shared.checkIfDue()
                    }
                } else {
                    for p in self.panels.values where p.isKeyWindow {
                        p.resignKey()
                    }
                }
            }

        // Debug aid: NOTCH_OPEN=1 opens the panel at launch (and optionally seeds
        // a result via NOTCH_DEMO=1) so the expanded glass can be inspected
        // without a live hover. No effect in normal use.
        let env = ProcessInfo.processInfo.environment
        if env["NOTCH_OPEN"] == "1" {
            model.openPanel(on: preferredScreen()?.displayID)
            if env["NOTCH_DEMO"] == "1" {
                // NOTCH_DEMO_TEXT lets us seed arbitrary markdown for inspecting
                // the answer renderer; falls back to the original one-liner.
                model.seedDemo(
                    question: env["NOTCH_DEMO_Q"] ?? "Explain liquid glass in one line",
                    answer: env["NOTCH_DEMO_TEXT"]
                        ?? "A material language built on translucency, refraction and flow — light passes **through** it, not just over it."
                )
            }
            // NOTCH_DEMO_THREAD=1 seeds a long multi-turn conversation so the
            // scrolling/edge-fade of the result view can be inspected at launch
            // without any clicking. Debug aid only.
            if env["NOTCH_DEMO_THREAD"] == "1" {
                model.seedDemoThread()
            }
            // NOTCH_DEMO_HISTORY=1 expands the recent list at launch so the idle
            // panel (RECENT header + Clear pill) can be inspected without a hover.
            if env["NOTCH_DEMO_HISTORY"] == "1" {
                model.showHistory = true
            }
        }
        // Debug aid: NOTCH_SETTINGS=1 opens the panel straight into the inline
        // settings view at launch (via the same path as ⌘,) so it can be
        // inspected/screenshotted without a hover. No effect in normal use.
        if env["NOTCH_SETTINGS"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                NotificationCenter.default.post(name: .openSettingsRequested, object: nil)
            }
        }
        // Re-diff the panels when the screen layout changes (display added or
        // removed, resolution change, notebook lid open/close, etc.).
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )

        // The Settings → Display placement choice creates/destroys panels live.
        NotificationCenter.default.addObserver(
            forName: .displayPlacementChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.rebuildPanels()
            }
        }

        // When the user saves an API key or switches providers in Settings,
        // rebuild the AI service so the next question goes live immediately — no
        // restart needed.
        NotificationCenter.default.addObserver(
            forName: .aiBackendChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.syncService()
            }
        }

        // Settings now live *inside* the panel (see `InlineSettingsView`), so the
        // request just opens the panel straight into the settings view. Making the
        // panel open also makes it the key window (via the `$open` observer above),
        // so the API-key field can take keystrokes immediately.
        NotificationCenter.default.addObserver(
            forName: .openSettingsRequested,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                withAnimation(.spring(response: 0.42, dampingFraction: 0.78)) {
                    // ⌘, can fire from anywhere — open on the screen the user is
                    // actually on (mouse position), not wherever the notch lives.
                    self.model.openSettings(on: self.displayForSummon())
                }
            }
        }

        // ⌘, opens Settings. This is a menu-bar-less accessory app, so the
        // standard menu item that would carry that shortcut doesn't exist — we
        // register a real system hot key (Carbon `RegisterEventHotKey`, no
        // accessibility permission required) so ⌘, works from anywhere. It posts
        // the same request the in-panel gear does, so both share one open path.
        settingsHotKey = HotKey(keyCode: UInt32(kVK_ANSI_Comma),
                                modifiers: UInt32(cmdKey)) {
            NotificationCenter.default.post(name: .openSettingsRequested, object: nil)
        }
    }

    @objc private func screensChanged() {
        rebuildPanels()
    }

    // MARK: - Panel management

    /// The screens that should carry a notch island under the current setting.
    private func targetScreens() -> [NSScreen] {
        switch DisplayPlacement.current {
        case .all:     return NSScreen.screens
        case .builtIn: return preferredScreen().map { [$0] } ?? []
        }
    }

    /// Create/destroy/re-pin panels so exactly the screens in `targetScreens()`
    /// have one. Called at launch, on screen layout changes, and when the
    /// Display setting flips. Surviving panels are only repositioned — never
    /// torn down — so flipping the setting from inside the open settings panel
    /// doesn't slam that panel shut.
    private func rebuildPanels() {
        var live: Set<CGDirectDisplayID> = []
        for screen in targetScreens() {
            guard let id = screen.displayID else { continue }
            live.insert(id)
            if let existing = panels[id] {
                position(existing, on: screen)
            } else {
                panels[id] = makePanel(on: screen, id: id)
            }
        }
        for (id, panel) in panels where !live.contains(id) {
            panel.close()
            panels.removeValue(forKey: id)
        }
        // If the open island's screen just vanished (display unplugged, placement
        // narrowed mid-use), migrate it to a surviving screen instead of dropping
        // the user's conversation / half-edited settings on the floor.
        if let active = model.activeDisplay, panels[active] == nil {
            model.activeDisplay = preferredScreen()?.displayID
        }
    }

    /// Build the transparent canvas panel for one screen, injecting per-screen
    /// metrics so the SwiftUI tree knows which display it's on, how tall its
    /// resting notch is, and whether to draw the camera dot.
    private func makePanel(on screen: NSScreen, id: CGDirectDisplayID) -> NotchPanel {
        let rect = NSRect(x: 0, y: 0, width: canvasWidth, height: canvasHeight)
        let panel = NotchPanel(contentRect: rect)

        let hasNotch = screen.safeAreaInsets.top > 0
        let root = ContentView(model: model)
            .frame(width: canvasWidth, height: canvasHeight, alignment: .top)
            .environment(\.notchMetrics, NotchMetrics(
                canvasWidth: canvasWidth,
                displayID: id,
                restHeight: hasNotch ? Tokens.notchTopHeight
                                     : Self.menuBarHeight(of: screen),
                hasHardwareNotch: hasNotch
            ))

        let hosting = NSHostingView(rootView: root)
        hosting.frame = rect
        // Let clicks pass through the transparent canvas to apps underneath;
        // only the glass form itself is interactive.
        panel.contentView = hosting

        position(panel, on: screen)
        panel.orderFrontRegardless()
        return panel
    }

    /// Center the canvas horizontally and flush its top edge to the very top of
    /// the screen, so the SwiftUI notch sits exactly where the hardware notch
    /// (or the menu bar, on external screens) is.
    private func position(_ panel: NSPanel, on screen: NSScreen) {
        let full = screen.frame
        let x = full.midX - canvasWidth / 2
        // AppKit's origin is bottom-left; place the canvas so its top aligns
        // with the screen's top edge.
        let y = full.maxY - canvasHeight
        panel.setFrame(NSRect(x: x, y: y, width: canvasWidth, height: canvasHeight),
                       display: true)
    }

    /// The resting-zone height for a notch-less screen: match the menu bar so
    /// the virtual notch nests inside it. `visibleFrame` already subtracts the
    /// menu bar from the top (the Dock only ever affects the bottom/sides);
    /// clamped so an auto-hidden menu bar can't yield a zero-height notch.
    private static func menuBarHeight(of screen: NSScreen) -> CGFloat {
        let h = screen.frame.maxY - screen.visibleFrame.maxY
        return h > 4 ? min(h, 40) : 24
    }

    /// Prefer the screen that actually has a notch (its `safeAreaInsets.top`
    /// exceeds the menu-bar height). Fall back to the main screen.
    private func preferredScreen() -> NSScreen? {
        if let notched = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) {
            return notched
        }
        return NSScreen.main ?? NSScreen.screens.first
    }

    /// Where a summoned-from-anywhere open (⌘,) should land: the screen the
    /// mouse is on when it has a panel, else the preferred screen.
    private func displayForSummon() -> CGDirectDisplayID? {
        let mouse = NSEvent.mouseLocation
        if let id = NSScreen.screens
            .first(where: { NSMouseInRect(mouse, $0.frame, false) })?.displayID,
           panels[id] != nil {
            return id
        }
        return preferredScreen()?.displayID
    }
}

/// Which screens carry a notch island — persisted in `UserDefaults`, edited in
/// Settings → Display, consumed by `AppDelegate.rebuildPanels()`.
enum DisplayPlacement: String, CaseIterable, Identifiable {
    /// Every connected screen gets an island: the real notch on the built-in
    /// display, a menu-bar-height virtual notch on externals. The default —
    /// the point of the app is being one hover away wherever you're working.
    case all
    /// The classic single-panel behavior: only the notched (or main) screen.
    case builtIn

    var id: String { rawValue }

    var label: String {
        switch self {
        case .all:     return "All displays"
        case .builtIn: return "Built-in display"
        }
    }

    private static let key = "displayPlacement"
    static var current: DisplayPlacement {
        get {
            UserDefaults.standard.string(forKey: key)
                .flatMap(DisplayPlacement.init) ?? .all
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: key)
        }
    }
}

extension NSScreen {
    /// The CoreGraphics display ID — the stable key panels are tracked by
    /// across layout changes.
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?
            .uint32Value
    }
}
