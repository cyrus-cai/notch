import AppKit

/// A borderless, transparent, always-on-top panel that hosts the notch UI.
///
/// It deliberately behaves like a system overlay rather than a normal window:
///  · no title bar / no shadow drawn by AppKit (the glass draws its own)
///  · transparent background so only the SwiftUI glass form is visible
///  · floats above every app and joins every Space / full-screen app
///  · non-activating, so clicking it never steals focus from the frontmost app
///    (it can still receive key events for the text field via `canBecomeKey`)
final class NotchPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        level = .statusBar                     // above menu bar / normal windows
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        titlebarAppearsTransparent = true
        hidesOnDeactivate = false
        isMovable = false
        isReleasedWhenClosed = false

        // Show on top of full-screen apps and follow the user across Spaces.
        collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .stationary,
            .ignoresCycle,
        ]
    }

    // A borderless panel returns false by default; allow it so the prompt field
    // can become first responder when the user types into the glass.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
