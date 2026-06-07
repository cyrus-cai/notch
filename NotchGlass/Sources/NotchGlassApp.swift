import SwiftUI

/// Entry point. The app runs as a UI-element (no Dock icon, no menu bar app
/// window) — it's a single floating panel that grows out of the Mac's notch.
/// The real work happens in `AppDelegate`, which owns the borderless panel.
@main
struct NotchGlassApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // No standard windows — everything lives in the notch panel created by
        // the AppDelegate. Settings now render *inside* that panel (see
        // `InlineSettingsView`), so there's no native preferences window anymore.
        // SwiftUI's `App` still requires at least one scene, so we keep an empty
        // `Settings` scene as an inert placeholder: nothing ever calls
        // `openSettings()`, so its (empty) window is never shown. ⌘, is handled by
        // the AppDelegate's hot key, which opens the in-panel settings instead.
        Settings { EmptyView() }
    }
}
