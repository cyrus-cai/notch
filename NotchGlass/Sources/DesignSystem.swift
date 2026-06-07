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

    // Status accents — used sparingly for inline feedback (e.g. the connectivity
    // test verdict). Tuned bright/saturated so they read clearly on the dark glass
    // without the muddiness a dimmed system red/green would have here.
    static let success = Color(red: 0.30, green: 0.85, blue: 0.45)
    static let danger  = Color(red: 1.00, green: 0.42, blue: 0.42)

    /// Placeholder text for the prompt — a soft, faint hint, clearly LIGHTER than
    /// real typed text so it reads as a transient suggestion rather than content.
    /// Kept low on the scale so "Ask anything" whispers instead of shouting.
    static let placeholder = ink.opacity(0.38)

    /// The warm "champagne gold" the record (note) surface tints its glass with, so
    /// it reads apart from the cold black chat glass at a glance. Very low chroma —
    /// a warm white, not yellow — so layered faintly over the dark veil it reads as
    /// a whisper of warmth rather than a coloured panel. The opacity it's applied at
    /// (see `GlassMaterial`) is what keeps it "极淡".
    static let champagne = Color(red: 1.00, green: 0.90, blue: 0.62)

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
}

extension Font {
    /// Native SF Text with optical sizing handled by the system. SwiftUI's
    /// `.system` already maps to San Francisco, so we just size/weight it.
    static func sf(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .default)
    }
}

/// Geometry shared with the SwiftUI tree via the environment so views know how
/// wide the transparent canvas is and can center the notch within it.
struct NotchMetrics {
    var canvasWidth: CGFloat
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
    var fade: CGFloat = 30

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
    func scrollEdgeFade(top: Bool, bottom: Bool, fade: CGFloat = 30) -> some View {
        modifier(ScrollEdgeFade(top: top, bottom: bottom, fade: fade))
    }
}
