#!/usr/bin/env swift
// Generates the NotchGlass app icon (all AppIcon.appiconset sizes + docs/icon.png).
//
// Usage (from the repo root):
//   swift scripts/generate_icon.swift
//
// The artwork is drawn full-bleed (no baked-in rounded corners or margins) so
// macOS 26+ can apply its own squircle mask and glass treatment. docs/icon.png
// gets the squircle baked in since GitHub renders it as a plain <img>.

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let CANVAS: CGFloat = 1024

func srgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: r, green: g, blue: b, alpha: a)
}

func gradient(_ stops: [(CGFloat, CGColor)]) -> CGGradient {
    CGGradient(
        colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
        colors: stops.map { $0.1 } as CFArray,
        locations: stops.map { $0.0 }
    )!
}

// MARK: - Notch geometry
//
// The notch floats in the upper-middle of the canvas: a thin menu-bar line
// whose tips flare gently upward, with the notch bowl hanging beneath it.

let barY: CGFloat = 360           // the menu-bar line the bowl hangs from
let notchWidth: CGFloat = 560
let notchHeight: CGFloat = 170
let filletRadius: CGFloat = 36    // concave fillets where the bowl meets the line
let cornerRadius: CGFloat = 66    // convex bottom corners

let notchLeft = (CANVAS - notchWidth) / 2
let notchRight = notchLeft + notchWidth
let notchBottom = barY + notchHeight

let barTipX: CGFloat = 168        // outer tip of the line (mirrored on the right)
let barTipLift: CGFloat = 16      // how far the tips flare upward
let barFlareEnd: CGFloat = 250    // where the flare levels out into the straight line

// The menu-bar line: straight in the middle, tips swept upward like wings.
func barPath() -> CGPath {
    let p = CGMutablePath()
    p.move(to: CGPoint(x: barTipX, y: barY - barTipLift))
    p.addQuadCurve(to: CGPoint(x: barFlareEnd, y: barY),
                   control: CGPoint(x: barFlareEnd - 35, y: barY))
    p.addLine(to: CGPoint(x: CANVAS - barFlareEnd, y: barY))
    p.addQuadCurve(to: CGPoint(x: CANVAS - barTipX, y: barY - barTipLift),
                   control: CGPoint(x: CANVAS - barFlareEnd + 35, y: barY))
    return p
}

// Closed path for the bowl's black fill (runs back along the bar line).
func notchFillPath() -> CGPath {
    let p = CGMutablePath()
    p.move(to: CGPoint(x: notchLeft - filletRadius * 2, y: barY))
    p.addArc(tangent1End: CGPoint(x: notchLeft, y: barY),
             tangent2End: CGPoint(x: notchLeft, y: notchBottom),
             radius: filletRadius)
    p.addArc(tangent1End: CGPoint(x: notchLeft, y: notchBottom),
             tangent2End: CGPoint(x: notchRight, y: notchBottom),
             radius: cornerRadius)
    p.addArc(tangent1End: CGPoint(x: notchRight, y: notchBottom),
             tangent2End: CGPoint(x: notchRight, y: barY),
             radius: cornerRadius)
    p.addArc(tangent1End: CGPoint(x: notchRight, y: barY),
             tangent2End: CGPoint(x: notchRight + filletRadius * 2, y: barY),
             radius: filletRadius)
    p.closeSubpath()
    return p
}

// Open path along the bowl silhouette (no top closure) for the rim stroke.
func notchRimPath() -> CGPath {
    let p = CGMutablePath()
    p.move(to: CGPoint(x: notchLeft - filletRadius, y: barY))
    p.addArc(tangent1End: CGPoint(x: notchLeft, y: barY),
             tangent2End: CGPoint(x: notchLeft, y: notchBottom),
             radius: filletRadius)
    p.addArc(tangent1End: CGPoint(x: notchLeft, y: notchBottom),
             tangent2End: CGPoint(x: notchRight, y: notchBottom),
             radius: cornerRadius)
    p.addArc(tangent1End: CGPoint(x: notchRight, y: notchBottom),
             tangent2End: CGPoint(x: notchRight, y: barY),
             radius: cornerRadius)
    p.addArc(tangent1End: CGPoint(x: notchRight, y: barY),
             tangent2End: CGPoint(x: notchRight + filletRadius, y: barY),
             radius: filletRadius)
    return p
}

// MARK: - Drawing (1024-space, y-down)

func drawArt(_ ctx: CGContext, bakeSquircle: Bool, scale: CGFloat) {
    let full = CGRect(x: 0, y: 0, width: CANVAS, height: CANVAS)

    if bakeSquircle {
        ctx.addPath(CGPath(roundedRect: full, cornerWidth: 232, cornerHeight: 232, transform: nil))
        ctx.clip()
    }

    // Base: deep blue-black vertical gradient.
    ctx.drawLinearGradient(
        gradient([
            (0.00, srgb(0.165, 0.205, 0.320)),
            (0.55, srgb(0.060, 0.082, 0.145)),
            (1.00, srgb(0.016, 0.024, 0.050)),
        ]),
        start: CGPoint(x: 512, y: 0), end: CGPoint(x: 512, y: CANVAS), options: []
    )

    // Wide aurora glow behind / below the notch.
    ctx.drawRadialGradient(
        gradient([
            (0.00, srgb(0.22, 0.48, 1.00, 0.60)),
            (0.45, srgb(0.16, 0.38, 1.00, 0.22)),
            (1.00, srgb(0.16, 0.38, 1.00, 0.00)),
        ]),
        startCenter: CGPoint(x: 512, y: 560), startRadius: 0,
        endCenter: CGPoint(x: 512, y: 560), endRadius: 620, options: []
    )

    // Bright cyan core backlighting the bowl.
    ctx.drawRadialGradient(
        gradient([
            (0.00, srgb(0.70, 0.92, 1.00, 0.85)),
            (0.55, srgb(0.45, 0.75, 1.00, 0.30)),
            (1.00, srgb(0.45, 0.75, 1.00, 0.00)),
        ]),
        startCenter: CGPoint(x: 512, y: 530), startRadius: 0,
        endCenter: CGPoint(x: 512, y: 530), endRadius: 340, options: []
    )

    // Soft shaft of light spilling down from the notch.
    ctx.saveGState()
    ctx.translateBy(x: 512, y: notchBottom)
    ctx.scaleBy(x: 1.0, y: 2.2)
    ctx.drawRadialGradient(
        gradient([
            (0.00, srgb(0.62, 0.84, 1.00, 0.30)),
            (0.60, srgb(0.45, 0.70, 1.00, 0.10)),
            (1.00, srgb(0.45, 0.70, 1.00, 0.00)),
        ]),
        startCenter: .zero, startRadius: 0,
        endCenter: .zero, endRadius: 250, options: []
    )
    ctx.restoreGState()

    // Corner vignette for depth.
    ctx.drawRadialGradient(
        gradient([
            (0.00, srgb(0, 0, 0, 0.00)),
            (0.70, srgb(0, 0, 0, 0.00)),
            (1.00, srgb(0, 0, 0, 0.30)),
        ]),
        startCenter: CGPoint(x: 512, y: 500), startRadius: 0,
        endCenter: CGPoint(x: 512, y: 500), endRadius: 820, options: []
    )

    // Faint sheen across the top, like light on glass.
    ctx.drawLinearGradient(
        gradient([
            (0.00, srgb(1, 1, 1, 0.07)),
            (1.00, srgb(1, 1, 1, 0.00)),
        ]),
        start: CGPoint(x: 512, y: 0), end: CGPoint(x: 512, y: 280), options: []
    )

    // Stroke widths are floored in device pixels so they survive small sizes.
    let barWidth = max(13, 1.4 / scale)
    let glowWidth = max(4, 1.6 / scale)
    let crispWidth = max(2.5, 1.1 / scale)
    ctx.setLineCap(.round)

    // The floating notch: menu-bar line + bowl, pure black with a soft blue halo.
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 46, color: srgb(0.35, 0.60, 1.00, 0.65))
    ctx.addPath(notchFillPath())
    ctx.setFillColor(srgb(0, 0, 0))
    ctx.fillPath()
    ctx.addPath(barPath())
    ctx.setStrokeColor(srgb(0, 0, 0))
    ctx.setLineWidth(barWidth)
    ctx.strokePath()
    ctx.restoreGState()

    // Glass rim: a glowing pass then a crisp pass along the bowl silhouette.
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 16, color: srgb(0.70, 0.85, 1.00, 0.85))
    ctx.addPath(notchRimPath())
    ctx.setStrokeColor(srgb(0.72, 0.86, 1.00, 0.55))
    ctx.setLineWidth(glowWidth)
    ctx.strokePath()
    ctx.restoreGState()

    ctx.addPath(notchRimPath())
    ctx.setStrokeColor(srgb(0.85, 0.93, 1.00, 0.65))
    ctx.setLineWidth(crispWidth)
    ctx.strokePath()

    // Light catching the top edge of the menu-bar line.
    ctx.saveGState()
    ctx.translateBy(x: 0, y: -(barWidth / 2 + 1))
    ctx.addPath(barPath())
    ctx.setStrokeColor(srgb(0.85, 0.93, 1.00, 0.55))
    ctx.setLineWidth(crispWidth)
    ctx.strokePath()
    ctx.restoreGState()

    if bakeSquircle {
        // Subtle inner light border (the OS draws its own on the real icon).
        ctx.addPath(CGPath(roundedRect: full.insetBy(dx: 2, dy: 2),
                           cornerWidth: 230, cornerHeight: 230, transform: nil))
        ctx.setStrokeColor(srgb(1, 1, 1, 0.10))
        ctx.setLineWidth(4)
        ctx.strokePath()
    }
}

// MARK: - Rendering / IO

func render(size: Int, bakeSquircle: Bool) -> CGImage {
    let ctx = CGContext(
        data: nil, width: size, height: size,
        bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    ctx.setAllowsAntialiasing(true)
    ctx.interpolationQuality = .high
    // Flip to a y-down, 1024-unit coordinate space.
    let scale = CGFloat(size) / CANVAS
    ctx.translateBy(x: 0, y: CGFloat(size))
    ctx.scaleBy(x: scale, y: -scale)
    drawArt(ctx, bakeSquircle: bakeSquircle, scale: scale)
    return ctx.makeImage()!
}

func writePNG(_ image: CGImage, to path: String) {
    let url = URL(fileURLWithPath: path)
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { fatalError("failed to write \(path)") }
    print("wrote \(path)")
}

let root = FileManager.default.currentDirectoryPath
let iconset = "\(root)/NotchGlass/Resources/Assets.xcassets/AppIcon.appiconset"

let appIconSizes: [(String, Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]

var rendered: [Int: CGImage] = [:]
for (name, size) in appIconSizes {
    let image = rendered[size] ?? render(size: size, bakeSquircle: false)
    rendered[size] = image
    writePNG(image, to: "\(iconset)/\(name)")
}

writePNG(render(size: 1024, bakeSquircle: true), to: "\(root)/docs/icon.png")
