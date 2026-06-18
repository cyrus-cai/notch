import SwiftUI

/// The one type + color system the whole notch references — a direct port of the
/// prototype's tokens (native San Francisco + a 4-level label scale that mirrors
/// macOS dark-mode label opacities). Nothing in the UI uses ad-hoc rgba values.
enum Tokens {
    /// Base "ink" for all text — a clean near-white. The idle prompt and labels
    /// live in the *upper, dark* part of the panel, so the scale is kept bright:
    /// opacity-on-dark below ~0.7 turns to muddy gray (the washed-out look we're
    /// fixing). Every level derives from this one ink so the text reads as one
    /// family, but no level drops so far that it greys out against the glass.
    static let ink = Color.white

    // Label scale — one ink, four levels (label / secondary / tertiary /
    // quaternary). Tuned brighter than stock macOS because our surface goes from
    // near-black at top to translucent glass at the bottom, and text must stay
    // crisp across both — a flat dim gray reads as broken on this material.
    static let text1 = ink.opacity(0.96)   // primary content (answers)
    static let text2 = ink.opacity(0.74)   // secondary (question echo)
    static let text3 = ink.opacity(0.55)   // labels (RECENT / Recent)
    static let text4 = ink.opacity(0.40)   // meta (timestamps)
    static let hairline = Color.white.opacity(0.12)

    // Danger accent — used sparingly for genuine errors and destructive actions
    // (update failure, a destructive menu item). Success/confirmation states stay
    // neutral ink instead: no coloured dots, no green pills.
    static let danger  = Color(red: 1.00, green: 0.42, blue: 0.42)

    /// Placeholder text for the prompt — a soft, faint hint, clearly LIGHTER than
    /// real typed text so it reads as a transient suggestion rather than content.
    /// Kept low on the scale so "Ask anything" whispers instead of shouting.
    static let placeholder = ink.opacity(0.38)

    // Resting notch dimensions — matched to the real MacBook hardware notch
    // (≈185pt wide × 32pt tall, ~9pt bottom corner radius) so the resting form
    // sits exactly over the bezel cutout rather than looking like a fat pill.
    static let notchWidth: CGFloat = 192
    static let notchTopHeight: CGFloat = 32        // constant black "hardware" zone
    static let notchRestRadius: CGFloat = 9        // resting bottom corner radius

    // Open widths per state — the island grows wider as content gets richer.
    static let openWidthIdle: CGFloat = 540
    static let openWidthLoad: CGFloat = 560
    static let openWidthResult: CGFloat = 600
    static let openWidthSettings: CGFloat = 580   // inline settings form
    static let openWidthWhatsNew: CGFloat = 600   // release-notes reading column
}

extension Font {
    /// Native SF Text with optical sizing handled by the system. SwiftUI's
    /// `.system` already maps to San Francisco, so we just size/weight it.
    static func sf(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .default)
    }

    /// The brand wordmark voice — Prompt (Medium / 500), bundled and registered
    /// via `ATSApplicationFontsPath` so it matches the "Notch" wordmark on the
    /// landing page (its `--brand` family). Used only for the name of the thing.
    static func brand(_ size: CGFloat) -> Font {
        .custom("Prompt-Medium", fixedSize: size)
    }
}

/// Geometry shared with the SwiftUI tree via the environment so views know how
/// wide the transparent canvas is and can center the notch within it.
///
/// Each panel (one per screen — see `AppDelegate`) injects its own copy, which is
/// how the same `ContentView` renders a hardware-notch-hugging island on the
/// built-in display and a menu-bar-height "virtual notch" on external ones.
struct NotchMetrics {
    var canvasWidth: CGFloat
    /// Stable identifier of the display this canvas sits on (`CGDirectDisplayID`).
    /// `nil` only in previews / the environment default; live panels always set it.
    var displayID: CGDirectDisplayID? = nil
    /// Height of the resting black zone: the hardware notch height on the built-in
    /// screen, the menu-bar height on external (notch-less) screens — so the
    /// virtual notch nests inside the menu bar instead of poking below it.
    var restHeight: CGFloat = Tokens.notchTopHeight
    /// Whether this screen has a real camera housing. Drives the camera dot —
    /// drawing a fake lens on an external monitor reads as a mistake.
    var hasHardwareNotch: Bool = true
}

private struct NotchMetricsKey: EnvironmentKey {
    static let defaultValue = NotchMetrics(canvasWidth: 760)
}

extension EnvironmentValues {
    var notchMetrics: NotchMetrics {
        get { self[NotchMetricsKey.self] }
        set { self[NotchMetricsKey.self] = newValue }
    }
}

// MARK: - Scroll edge fade

/// The one soft-fade treatment every scrolling region in the panel shares, so
/// overflowing content dissolves into the glass instead of ending on a hard
/// horizontal cut. Applied as a luminance mask: a long, gentle taper at the top
/// and/or bottom edge, sized in *points* (so the dissolve looks the same whatever
/// the content height) and converted to the gradient's 0–1 space using the view's
/// own measured height. Reused by the conversation thread and the RECENT list —
/// don't hand-roll a per-view gradient; route every scroll area through here.
struct ScrollEdgeFade: ViewModifier {
    /// Whether to taper the top / bottom edge. A region pinned under a header
    /// (so its top never overflows) can fade only the bottom, and vice versa.
    var top: Bool
    var bottom: Bool
    /// Height of each taper, in points. Generous on purpose so the fade is a long
    /// gradient, not a thin line that still reads as a cut.
    var fade: CGFloat = 64

    func body(content: Content) -> some View {
        content.mask(
            GeometryReader { geo in
                let h = max(geo.size.height, 1)
                // Clamp so the two tapers can't overlap on a short area.
                let f = min(fade / h, 0.45)
                LinearGradient(
                    stops: [
                        .init(color: .black.opacity(top ? 0 : 1), location: 0),
                        .init(color: .black, location: top ? f : 0),
                        .init(color: .black, location: bottom ? 1 - f : 1),
                        .init(color: .black.opacity(bottom ? 0 : 1), location: 1),
                    ],
                    startPoint: .top, endPoint: .bottom
                )
            }
        )
    }
}

extension View {
    /// Apply the shared scroll edge fade (see `ScrollEdgeFade`). Pass `top` /
    /// `bottom` to choose which edges taper; usually gated on whether the content
    /// actually overflows, so a short list/thread stays crisp.
    func scrollEdgeFade(top: Bool, bottom: Bool, fade: CGFloat = 64) -> some View {
        modifier(ScrollEdgeFade(top: top, bottom: bottom, fade: fade))
    }
}

// MARK: - Progressive top blur

/// A variable ("progressive") blur on the TOP band of a view — sharp at the
/// bottom, blurring harder the closer a pixel sits to the top edge. SwiftUI has
/// no native variable blur on the 14.0 baseline, so we approximate the smooth
/// ramp by stacking a few uniformly-blurred copies of the same content, each
/// masked to a gradient band: the strongest blur is masked to the very top, the
/// gentlest reaches further down, and the un-blurred original shows through
/// below. Composited together they read as one continuous frost that deepens
/// upward — the look of rows dissolving *behind* the floating input header.
///
/// This is the partner to `ScrollEdgeFade`: that mask handles *opacity* (rows
/// thin out toward the top), this handles *focus* (rows frost out toward the
/// top). Used together, content scrolling up under the input stays faintly
/// perceivable — present, but pushed back — instead of hard-clipping.
///
/// Kept to a small fixed layer count: each layer is another render of the
/// content, so this is only worth applying to a region that actually overflows
/// and scrolls under a header. A short list that fits needs neither.
struct ProgressiveTopBlur: ViewModifier {
    /// Height of the blur band, in points, measured from the top edge down.
    /// Below this the content is fully sharp.
    var height: CGFloat
    /// Peak blur radius at the very top edge. Each layer steps up toward this.
    var maxRadius: CGFloat = 7

    /// Four frost layers plus the sharp original read as a smooth ramp without the
    /// cost of a dozen renders. Each layer's blur radius and the depth its mask
    /// reaches are paced so the strongest frost hugs the top and the lightest blends
    /// into the sharp content below. Four (vs three) keeps the ramp smooth at the
    /// heavier radius the immersive prompt now uses, without banding.
    private let layers = 4

    func body(content: Content) -> some View {
        content.overlay(
            GeometryReader { geo in
                let h = max(geo.size.height, 1)
                // The blur band as a fraction of the view height, clamped so it
                // never swallows the whole region on a short view.
                let band = min(height / h, 0.9)
                ZStack {
                    ForEach(0..<layers, id: \.self) { i in
                        // i = 0 is the gentlest, reaching deepest; the last layer
                        // is the strongest, hugging the very top. Step the radius
                        // up and the mask depth in toward the top edge.
                        let t = CGFloat(i + 1) / CGFloat(layers)   // 0…1
                        let radius = maxRadius * t
                        // This layer's frost is visible from the top down to
                        // `depth`, then fades out — deeper layers (gentle) reach
                        // further, shallow layers (strong) stay near the top.
                        let depth = band * (1 - t) + band * 0.34
                        content
                            .blur(radius: radius)
                            .mask(
                                LinearGradient(
                                    stops: [
                                        .init(color: .black, location: 0),
                                        .init(color: .black, location: max(depth - band * 0.34, 0)),
                                        .init(color: .clear, location: depth),
                                        .init(color: .clear, location: 1),
                                    ],
                                    startPoint: .top, endPoint: .bottom
                                )
                            )
                    }
                }
                // The frost overlay must not intercept clicks — the live, sharp
                // scroll content beneath owns all hit-testing (taps on rows).
                .allowsHitTesting(false)
            }
        )
    }
}

extension View {
    /// Frost the top band of a scrolling region so rows passing behind a floating
    /// header blur out progressively (see `ProgressiveTopBlur`). Pair with
    /// `scrollEdgeFade(top:)` for the matching opacity taper.
    func progressiveTopBlur(height: CGFloat, maxRadius: CGFloat = 7) -> some View {
        modifier(ProgressiveTopBlur(height: height, maxRadius: maxRadius))
    }
}

/// Apply `ProgressiveTopBlur` only when `active` — and, crucially, mount/unmount
/// the blur stack rather than just zeroing its radius, so the compact list never
/// pays for the extra renders. A plain `if active` inside a `ViewModifier` would
/// change the view's identity; wrapping the toggle here keeps it contained.
struct ConditionalTopBlur: ViewModifier {
    var active: Bool
    var height: CGFloat
    var maxRadius: CGFloat = 7

    func body(content: Content) -> some View {
        if active {
            content.progressiveTopBlur(height: height, maxRadius: maxRadius)
        } else {
            content
        }
    }
}

// MARK: - Scroll offset observer

/// Reports a SwiftUI `ScrollView`'s live vertical scroll offset by reaching the
/// AppKit `NSScrollView` underneath it. The pure-SwiftUI routes (a GeometryReader
/// preference probe, or an onAppear/onDisappear sentinel) are unreliable on the
/// classic macOS 14 `ScrollView` — it neither exposes a stable offset nor recycles
/// off-screen children — so we observe the real clip view's bounds instead, which
/// is exact and immune to how SwiftUI composes (e.g. the blur overlay's content
/// copies). Drop this as a zero-size `background` on the scroll *content*; it finds
/// its enclosing scroll view at runtime and calls `onChange` with `bounds.origin.y`
/// (0 at the top, growing as the user scrolls down).
struct ScrollOffsetObserver: NSViewRepresentable {
    var onChange: (CGFloat) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onChange: onChange) }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        // Defer the hookup: the view isn't in the window's hierarchy yet during
        // make, so the enclosing NSScrollView can't be found until the next runloop.
        DispatchQueue.main.async { context.coordinator.attach(from: view) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onChange = onChange
        // Re-attach if the scroll view wasn't ready at make time (or got replaced).
        if context.coordinator.clipView == nil {
            DispatchQueue.main.async { context.coordinator.attach(from: nsView) }
        }
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.detach()
    }

    final class Coordinator {
        var onChange: (CGFloat) -> Void
        weak var clipView: NSClipView?

        init(onChange: @escaping (CGFloat) -> Void) { self.onChange = onChange }

        func attach(from view: NSView) {
            guard let scrollView = view.enclosingScrollView else { return }
            let clip = scrollView.contentView
            clip.postsBoundsChangedNotifications = true
            clipView = clip
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(boundsChanged(_:)),
                name: NSView.boundsDidChangeNotification,
                object: clip
            )
            // Report the initial offset so a list that opens already-scrolled is
            // classified correctly on first paint.
            report(clip)
        }

        func detach() {
            NotificationCenter.default.removeObserver(self)
            clipView = nil
        }

        @objc private func boundsChanged(_ note: Notification) {
            guard let clip = note.object as? NSClipView else { return }
            report(clip)
        }

        private func report(_ clip: NSClipView) {
            onChange(clip.bounds.origin.y)
        }
    }
}

extension View {
    /// Observe the enclosing scroll view's vertical offset (see `ScrollOffsetObserver`).
    func onScrollOffsetChange(_ action: @escaping (CGFloat) -> Void) -> some View {
        background(ScrollOffsetObserver(onChange: action))
    }
}
