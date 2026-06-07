import SwiftUI
import AppKit

// Renders the SimpleNotch app icon to a 1024×1024 PNG.
//
// Design: an extremely faint cool-blue radial gradient (bright-ish at center,
// dissolving to near-white at the edges) with a centered, glassy / outlined Mac
// notch sitting on top. Minimal, calm, very pale.

// MARK: - The notch outline

/// The classic MacBook notch shape: flat top, two concave shoulders easing into
/// the surrounding surface, and a rounded-rectangle bottom. One continuous path.
struct NotchShape: Shape {
    var shoulder: CGFloat
    var bottom: CGFloat

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let w = rect.width, h = rect.height
        let s = min(shoulder, h)
        let b = min(bottom, h - s, w / 2)

        p.move(to: CGPoint(x: 0, y: 0))
        // Left concave shoulder.
        p.addQuadCurve(to: CGPoint(x: s, y: s), control: CGPoint(x: s, y: 0))
        p.addLine(to: CGPoint(x: s, y: h - b))
        // Bottom-left round.
        p.addQuadCurve(to: CGPoint(x: s + b, y: h), control: CGPoint(x: s, y: h))
        p.addLine(to: CGPoint(x: w - s - b, y: h))
        // Bottom-right round.
        p.addQuadCurve(to: CGPoint(x: w - s, y: h - b), control: CGPoint(x: w - s, y: h))
        p.addLine(to: CGPoint(x: w - s, y: s))
        // Right concave shoulder.
        p.addQuadCurve(to: CGPoint(x: w, y: 0), control: CGPoint(x: w - s, y: 0))
        p.closeSubpath()
        return p
    }
}

// MARK: - Icon artwork

struct IconView: View {
    /// Full canvas size in points (1024 for the master icon).
    let size: CGFloat

    var body: some View {
        // macOS Big Sur+ icons sit on a rounded-square "squircle" with a small
        // margin around the artwork. We draw the whole tile (gradient + notch),
        // then clip it to that rounded square.
        let corner = size * 0.2237        // Apple's icon corner ratio
        let inset = size * 0.0            // gradient fills the full tile

        ZStack {
            // Faint cool-blue radial gradient: palest blue at the center,
            // dissolving to near-white at the edges. Kept very, very light.
            RadialGradient(
                gradient: Gradient(stops: [
                    .init(color: Color(red: 0.83, green: 0.90, blue: 1.00), location: 0.0),
                    .init(color: Color(red: 0.92, green: 0.95, blue: 1.00), location: 0.45),
                    .init(color: Color(red: 0.985, green: 0.99, blue: 1.00), location: 1.0),
                ]),
                center: .center,
                startRadius: 0,
                endRadius: size * 0.62
            )

            // The notch, centered. Sized as a fraction of the canvas so it scales
            // cleanly to every icon resolution.
            notch
        }
        .frame(width: size - inset * 2, height: size - inset * 2)
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
        // A hairline edge so the pale tile still reads as a defined icon.
        .overlay(
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .strokeBorder(Color(red: 0.80, green: 0.86, blue: 0.97).opacity(0.55),
                              lineWidth: max(1, size * 0.0015))
        )
        .frame(width: size, height: size)
    }

    /// Glassy / outlined notch: a soft translucent fill catching the blue, a
    /// crisp outline, and a faint top highlight to give it a glass read.
    private var notch: some View {
        let notchW = size * 0.46
        let notchH = size * 0.135
        let shape = NotchShape(shoulder: notchH * 0.42, bottom: notchH * 0.55)

        // Translucent glass body — slightly deeper blue at the top so light reads
        // as coming from above.
        let bodyFill = LinearGradient(
            gradient: Gradient(colors: [
                Color(red: 0.36, green: 0.50, blue: 0.78).opacity(0.30),
                Color(red: 0.55, green: 0.66, blue: 0.88).opacity(0.16),
            ]),
            startPoint: .top, endPoint: .bottom
        )
        let outlineColor = Color(red: 0.30, green: 0.42, blue: 0.70).opacity(0.85)
        let sheenMask = LinearGradient(
            gradient: Gradient(colors: [.white, .clear]),
            startPoint: .top, endPoint: .center
        )

        let glass = ZStack {
            shape.fill(bodyFill)
            shape.stroke(outlineColor, lineWidth: max(1, size * 0.0045))
            // Faint inner highlight along the top edge → glassy sheen.
            shape
                .stroke(Color.white.opacity(0.6), lineWidth: max(1, size * 0.004))
                .blur(radius: size * 0.004)
                .mask(sheenMask)
        }
        .frame(width: notchW, height: notchH)

        // Soft contact shadow so the notch sits on the surface, not floating.
        return glass.shadow(
            color: Color(red: 0.25, green: 0.35, blue: 0.60).opacity(0.18),
            radius: size * 0.012, x: 0, y: size * 0.006
        )
    }
}

// MARK: - Render to PNG

@MainActor
func renderIcon(size: CGFloat, to url: URL) throws {
    let view = IconView(size: size).frame(width: size, height: size)
    let renderer = ImageRenderer(content: view)
    renderer.scale = 1.0
    renderer.isOpaque = false

    guard let nsImage = renderer.nsImage,
          let tiff = nsImage.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "render", code: 1)
    }
    try png.write(to: url)
}

// MARK: - main

@main
struct Main {
    static func main() throws {
        let out = CommandLine.arguments.count > 1
            ? CommandLine.arguments[1]
            : "icon_1024.png"
        let size = CommandLine.arguments.count > 2
            ? CGFloat(Double(CommandLine.arguments[2]) ?? 1024)
            : 1024
        let url = URL(fileURLWithPath: out)
        try MainActor.assumeIsolated {
            try renderIcon(size: size, to: url)
        }
        print("wrote \(out) @ \(Int(size))px")
    }
}
