import AppKit
import Carbon.HIToolbox
import Combine
import SwiftUI

/// Owns the notch panel for the lifetime of the app and keeps it pinned to the
/// top-center of the screen that holds the menu bar (the one with the notch).
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var panel: NotchPanel!
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

        let rect = NSRect(x: 0, y: 0, width: canvasWidth, height: canvasHeight)
        panel = NotchPanel(contentRect: rect)

        let root = ContentView(model: model)
            .frame(width: canvasWidth, height: canvasHeight, alignment: .top)
            .environment(\.notchMetrics, NotchMetrics(canvasWidth: canvasWidth))

        let hosting = NSHostingView(rootView: root)
        hosting.frame = rect
        // Let clicks pass through the transparent canvas to apps underneath;
        // only the glass form itself is interactive.
        panel.contentView = hosting

        position(panel)
        panel.orderFrontRegardless()

        // When the panel opens (on hover), make it the key window so keystrokes
        // land in the prompt field immediately — no extra click needed. Because
        // it's a non-activating panel, this grabs keyboard focus WITHOUT stealing
        // app activation or the menu bar from the frontmost app. On close, hand
        // key status back so we never hold the keyboard while resting.
        openObserver = model.$open
            .removeDuplicates()
            .sink { [weak self] isOpen in
                guard let self else { return }
                if isOpen {
                    self.panel.makeKeyAndOrderFront(nil)
                } else if self.panel.isKeyWindow {
                    self.panel.resignKey()
                }
            }

        // Debug aid: NOTCH_OPEN=1 opens the panel at launch (and optionally seeds
        // a result via NOTCH_DEMO=1) so the expanded glass can be inspected
        // without a live hover. No effect in normal use.
        let env = ProcessInfo.processInfo.environment
        if env["NOTCH_OPEN"] == "1" {
            model.open = true
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
        // Re-pin when the screen layout changes (display added, resolution
        // change, notebook lid open/close, etc.).
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )

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
                withAnimation(.spring(response: 0.42, dampingFraction: 0.78)) {
                    self?.model.openSettings()
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
        position(panel)
    }

    /// Center the canvas horizontally and flush its top edge to the very top of
    /// the screen, so the SwiftUI notch sits exactly where the hardware notch is.
    private func position(_ panel: NSPanel) {
        guard let screen = notchScreen() else { return }
        let full = screen.frame
        let x = full.midX - canvasWidth / 2
        // AppKit's origin is bottom-left; place the canvas so its top aligns
        // with the screen's top edge.
        let y = full.maxY - canvasHeight
        panel.setFrame(NSRect(x: x, y: y, width: canvasWidth, height: canvasHeight),
                       display: true)
    }

    /// Prefer the screen that actually has a notch (its `safeAreaInsets.top`
    /// exceeds the menu-bar height). Fall back to the main screen.
    private func notchScreen() -> NSScreen? {
        if let notched = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) {
            return notched
        }
        return NSScreen.main ?? NSScreen.screens.first
    }
}
