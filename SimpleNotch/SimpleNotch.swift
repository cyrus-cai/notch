import SwiftUI

// MARK: - App entry

@main
struct SimpleNotchApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        // A fixed, content-driven window — minimal chrome, just the canvas.
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)
    }
}

// MARK: - Canvas

struct ContentView: View {
    var body: some View {
        ZStack {
            // Background: an extremely faint blue, brightest at the center and
            // dissolving outward to plain white. Kept very, very pale on purpose.
            RadialGradient(
                gradient: Gradient(colors: [
                    Color(red: 0.90, green: 0.94, blue: 1.00),   // faintest blue, center
                    Color(red: 0.97, green: 0.98, blue: 1.00),   // almost white
                    Color.white                                   // edges
                ]),
                center: .center,
                startRadius: 0,
                endRadius: 520
            )
            .ignoresSafeArea()

            // The Mac notch, centered.
            NotchShape()
                .fill(Color.black)
                .frame(width: 200, height: 34)
                // A whisper of depth so it reads as carved out of the surface.
                .shadow(color: .black.opacity(0.18), radius: 8, x: 0, y: 4)
        }
        .frame(width: 720, height: 460)
    }
}

// MARK: - Notch geometry

/// The classic MacBook notch outline: a flat top edge, two outward-curving
/// shoulders that ease into the surrounding bezel, and a rounded-rectangle
/// bottom. Drawn as a single continuous path so the corners flow smoothly.
struct NotchShape: Shape {
    /// Radius of the small concave "shoulder" curves where the notch meets the
    /// top edge on each side.
    var shoulder: CGFloat = 10
    /// Radius of the two rounded bottom corners.
    var bottom: CGFloat = 12

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let w = rect.width
        let h = rect.height
        let s = min(shoulder, h)
        let b = min(bottom, h - s, w / 2)

        // Start just outside the top-left, on the flat top edge.
        p.move(to: CGPoint(x: 0, y: 0))

        // Left shoulder: concave curve sweeping down-and-in from the top edge.
        p.addQuadCurve(
            to: CGPoint(x: s, y: s),
            control: CGPoint(x: s, y: 0)
        )

        // Down the left wall to where the bottom-left round begins.
        p.addLine(to: CGPoint(x: s, y: h - b))

        // Bottom-left rounded corner.
        p.addQuadCurve(
            to: CGPoint(x: s + b, y: h),
            control: CGPoint(x: s, y: h)
        )

        // Across the flat bottom.
        p.addLine(to: CGPoint(x: w - s - b, y: h))

        // Bottom-right rounded corner.
        p.addQuadCurve(
            to: CGPoint(x: w - s, y: h - b),
            control: CGPoint(x: w - s, y: h)
        )

        // Up the right wall.
        p.addLine(to: CGPoint(x: w - s, y: s))

        // Right shoulder: concave curve sweeping up-and-out to the top edge.
        p.addQuadCurve(
            to: CGPoint(x: w, y: 0),
            control: CGPoint(x: w - s, y: 0)
        )

        // Close along the top edge.
        p.closeSubpath()
        return p
    }
}

#Preview {
    ContentView()
}
