// Draws the app icon: a monitor, seen from slightly to its left, with a sprig of thyme on its screen.
// swift Tools/AppIcon.swift ScreenThyme/Assets.xcassets/AppIcon.appiconset/AppIcon.png
//
// The monitor's face (bezel, screen, thyme) is drawn flat, then warped into perspective with Core Image.

import AppKit
import CoreGraphics
import CoreImage

let size: CGFloat = 1024
let out = CommandLine.arguments.dropFirst().first ?? "AppIcon.png"
let space = CGColorSpace(name: CGColorSpace.sRGB)!

// Top-left origin, y down, in points; `scale` pixels per point.
func makeContext(width: CGFloat, height: CGFloat, scale: CGFloat = 1, opaque: Bool) -> CGContext {
    let c = CGContext(data: nil, width: Int(width * scale), height: Int(height * scale), bitsPerComponent: 8, bytesPerRow: 0,
                      space: space, bitmapInfo: (opaque ? CGImageAlphaInfo.noneSkipLast : .premultipliedLast).rawValue)!
    c.translateBy(x: 0, y: height * scale)
    c.scaleBy(x: scale, y: -scale)
    return c
}

var ctx = makeContext(width: size, height: size, opaque: true)

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

func linear(_ colors: [CGColor], from: CGPoint, to: CGPoint) {
    let g = CGGradient(colorsSpace: space, colors: colors as CFArray, locations: nil)!
    ctx.drawLinearGradient(g, start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
}

func radial(_ colors: [CGColor], at c: CGPoint, radius: CGFloat) {
    let g = CGGradient(colorsSpace: space, colors: colors as CFArray, locations: nil)!
    ctx.drawRadialGradient(g, startCenter: c, startRadius: 0, endCenter: c, endRadius: radius, options: [])
}

func clipped(_ path: CGPath, _ body: () -> Void) {
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    body()
    ctx.restoreGState()
}

func polygon(_ p: [CGPoint]) -> CGPath {
    let path = CGMutablePath()
    path.addLines(between: p)
    path.closeSubpath()
    return path
}

// MARK: Flat face

let bezel = CGRect(x: 104, y: 182, width: 816, height: 520)
let screen = bezel.insetBy(dx: 30, dy: 30)
let bezelPath = CGPath(roundedRect: bezel, cornerWidth: 46, cornerHeight: 46, transform: nil)
let screenPath = CGPath(roundedRect: screen, cornerWidth: 18, cornerHeight: 18, transform: nil)

/// Renders `body` into a transparent bezel-sized image, at 2× for a clean warp.
func renderFace(_ body: () -> Void) -> CGImage {
    let saved = ctx
    ctx = makeContext(width: bezel.width, height: bezel.height, scale: 2, opaque: false)
    ctx.translateBy(x: -bezel.minX, y: -bezel.minY)
    body()
    let image = ctx.makeImage()!
    ctx = saved
    return image
}

func bezier(_ p: [CGPoint], _ t: CGFloat) -> CGPoint {
    let u = 1 - t
    let a = u * u * u, b = 3 * u * u * t, c = 3 * u * t * t, d = t * t * t
    return CGPoint(x: a * p[0].x + b * p[1].x + c * p[2].x + d * p[3].x,
                   y: a * p[0].y + b * p[1].y + c * p[2].y + d * p[3].y)
}

func angle(_ p: [CGPoint], _ t: CGFloat) -> CGFloat {
    let a = bezier(p, max(0, t - 0.01)), b = bezier(p, min(1, t + 0.01))
    return atan2(b.y - a.y, b.x - a.x)
}

func stroke(_ p: [CGPoint], from w0: CGFloat, to w1: CGFloat) {
    let n = 80
    ctx.setLineCap(.round)
    for i in 0..<n {
        let t0 = CGFloat(i) / CGFloat(n), t1 = CGFloat(i + 1) / CGFloat(n)
        ctx.setLineWidth(w0 + (w1 - w0) * t0)
        ctx.move(to: bezier(p, t0))
        ctx.addLine(to: bezier(p, t1))
        ctx.strokePath()
    }
}

func leaf(at p: CGPoint, angle a: CGFloat, length l: CGFloat) {
    let w = l * 0.42
    ctx.saveGState()
    ctx.translateBy(x: p.x, y: p.y)
    ctx.rotate(by: a)
    let path = CGMutablePath()
    path.move(to: .zero)
    path.addCurve(to: CGPoint(x: l, y: 0), control1: CGPoint(x: l * 0.2, y: w), control2: CGPoint(x: l * 0.8, y: w * 0.8))
    path.addCurve(to: .zero, control1: CGPoint(x: l * 0.8, y: -w * 0.8), control2: CGPoint(x: l * 0.2, y: -w))
    ctx.addPath(path)
    ctx.setFillColor(rgb(0x2F5A1C))
    ctx.fillPath()
    clipped(path) {
        linear([rgb(0x8CC152), rgb(0x5E9A34), rgb(0x3F7424)],
               from: CGPoint(x: 0, y: -w), to: CGPoint(x: 0, y: w))
        ctx.setFillColor(rgb(0xD8F0A8, 0.35))
        ctx.fillEllipse(in: CGRect(x: l * 0.22, y: -w * 0.55, width: l * 0.5, height: w * 0.4))
    }
    ctx.addPath(path)
    ctx.setStrokeColor(rgb(0x2C5418, 0.9))
    ctx.setLineWidth(max(1.5, l * 0.05))
    ctx.strokePath()
    ctx.move(to: CGPoint(x: l * 0.12, y: 0))
    ctx.addLine(to: CGPoint(x: l * 0.7, y: 0))
    ctx.setStrokeColor(rgb(0x2C5418, 0.45))
    ctx.setLineWidth(max(1, l * 0.03))
    ctx.strokePath()
    ctx.restoreGState()
}

struct Sprig {
    var points: [CGPoint]
    var width: (CGFloat, CGFloat)
    var nodes: [CGFloat]       // where leaf pairs grow, as t along the curve
    var leaf: (CGFloat, CGFloat) // leaf length at the first and last node
}

// Main stem runs left to right, rising; two branches climb, one dips.
let main = Sprig(points: [CGPoint(x: 196, y: 548), CGPoint(x: 380, y: 520), CGPoint(x: 610, y: 488), CGPoint(x: 836, y: 372)],
                 width: (15, 7), nodes: [0.16, 0.27, 0.38, 0.49, 0.6, 0.7, 0.79, 0.87, 0.94], leaf: (66, 42))
let up1 = Sprig(points: [bezier(main.points, 0.4), CGPoint(x: 432, y: 450), CGPoint(x: 420, y: 380), CGPoint(x: 452, y: 300)],
                width: (9, 5), nodes: [0.25, 0.45, 0.63, 0.8], leaf: (56, 36))
let up2 = Sprig(points: [bezier(main.points, 0.66), CGPoint(x: 680, y: 420), CGPoint(x: 660, y: 340), CGPoint(x: 700, y: 278)],
                width: (9, 5), nodes: [0.25, 0.45, 0.63, 0.8], leaf: (56, 36))
let down = Sprig(points: [bezier(main.points, 0.53), CGPoint(x: 560, y: 540), CGPoint(x: 560, y: 580), CGPoint(x: 590, y: 612)],
                 width: (8, 5), nodes: [0.4, 0.7], leaf: (50, 38))
let sprigs = [main, up1, up2, down]

func drawThyme() {
    ctx.saveGState()
    ctx.addPath(screenPath)
    ctx.clip()
    ctx.setShadow(offset: CGSize(width: 0, height: -16), blur: 32, color: rgb(0x0A2A5A, 0.6))
    ctx.beginTransparencyLayer(auxiliaryInfo: nil)
    for s in sprigs {
        ctx.setStrokeColor(rgb(0x7E8A3E))
        stroke(s.points, from: s.width.0, to: s.width.1)
    }
    for s in sprigs {
        for (i, t) in s.nodes.enumerated() {
            let f = s.nodes.count > 1 ? CGFloat(i) / CGFloat(s.nodes.count - 1) : 0
            let l = s.leaf.0 + (s.leaf.1 - s.leaf.0) * f
            let p = bezier(s.points, t), a = angle(s.points, t)
            let spread: CGFloat = 0.95 - 0.25 * f
            // Young leaves in the axils, then the main pair over them
            leaf(at: p, angle: a - 0.4, length: l * 0.55)
            leaf(at: p, angle: a + 0.4, length: l * 0.5)
            leaf(at: p, angle: a - spread, length: l)
            leaf(at: p, angle: a + spread, length: l * 0.92)
        }
        // Tip: a tight cluster of young leaves
        let tip = bezier(s.points, 1), a = angle(s.points, 1)
        let l = s.leaf.1 * 0.85
        leaf(at: tip, angle: a - 0.55, length: l)
        leaf(at: tip, angle: a + 0.55, length: l)
        leaf(at: tip, angle: a, length: l * 0.9)
    }
    ctx.endTransparencyLayer()
    ctx.restoreGState()
}

let face = renderFace {
    clipped(bezelPath) {
        linear([rgb(0x3B3F47), rgb(0x1A1C20), rgb(0x0F1013)],
               from: CGPoint(x: 0, y: bezel.minY), to: CGPoint(x: 0, y: bezel.maxY))
    }
    ctx.addPath(CGPath(roundedRect: bezel.insetBy(dx: 2, dy: 2), cornerWidth: 44, cornerHeight: 44, transform: nil))
    ctx.setStrokeColor(rgb(0xFFFFFF, 0.14))
    ctx.setLineWidth(4)
    ctx.strokePath()

    clipped(screenPath) {
        linear([rgb(0x63B4F2), rgb(0x2C7FD6), rgb(0x1757AE)],
               from: CGPoint(x: screen.minX, y: screen.minY), to: CGPoint(x: screen.maxX, y: screen.maxY))
        radial([rgb(0xE9F6FF, 0.75), rgb(0xBFE3FF, 0.25), rgb(0xBFE3FF, 0)],
               at: CGPoint(x: screen.midX - 10, y: screen.midY - 10), radius: 380)
    }
    drawThyme()

    // Glass sheen across the top-left of the screen
    clipped(screenPath) {
        clipped(polygon([CGPoint(x: screen.minX, y: screen.minY), CGPoint(x: screen.minX + 430, y: screen.minY),
                         CGPoint(x: screen.minX, y: screen.minY + 300)])) {
            linear([rgb(0xFFFFFF, 0.18), rgb(0xFFFFFF, 0)],
                   from: CGPoint(x: screen.minX, y: screen.minY), to: CGPoint(x: screen.minX + 200, y: screen.minY + 160))
        }
    }
}

// The monitor's back, seen as its left side edge: the bezel silhouette in a lighter grey.
let back = renderFace {
    clipped(bezelPath) {
        linear([rgb(0x5A5F69), rgb(0x2E3138), rgb(0x1E2024)],
               from: CGPoint(x: 0, y: bezel.minY), to: CGPoint(x: 0, y: bezel.maxY))
    }
}

// MARK: Perspective

/// Draws `image` with its corners at `quad` (top-left, top-right, bottom-right, bottom-left, y down).
func drawWarped(_ image: CGImage, to quad: [CGPoint], shadow: CGFloat = 0) {
    let up = { (p: CGPoint) in CIVector(x: p.x, y: size - p.y) }
    let filter = CIFilter(name: "CIPerspectiveTransform")!
    filter.setValue(CIImage(cgImage: image), forKey: kCIInputImageKey)
    filter.setValue(up(quad[0]), forKey: "inputTopLeft")
    filter.setValue(up(quad[1]), forKey: "inputTopRight")
    filter.setValue(up(quad[2]), forKey: "inputBottomRight")
    filter.setValue(up(quad[3]), forKey: "inputBottomLeft")
    let output = filter.outputImage!
    let warped = CIContext(options: [.workingColorSpace: space]).createCGImage(output, from: output.extent)!

    ctx.saveGState()
    ctx.translateBy(x: 0, y: size)
    ctx.scaleBy(x: 1, y: -1)
    if shadow > 0 {
        ctx.setShadow(offset: CGSize(width: 10, height: -shadow * 0.5), blur: shadow, color: rgb(0x5A4A2A, 0.45))
    }
    ctx.draw(warped, in: output.extent)
    ctx.restoreGState()
}

// The left edge is nearer, so taller; the right edge recedes.
let tl = CGPoint(x: 132, y: 168), tr = CGPoint(x: 912, y: 206)
let br = CGPoint(x: 912, y: 628), bl = CGPoint(x: 132, y: 690)
let depth: CGFloat = 12
let backQuad = [CGPoint(x: tl.x - depth, y: tl.y + 4), CGPoint(x: tr.x - depth, y: tr.y + 3),
                CGPoint(x: br.x - depth, y: br.y - 3), CGPoint(x: bl.x - depth, y: bl.y - 4)]

// MARK: Compose

linear([rgb(0xFBF7EC), rgb(0xEADFC6)], from: CGPoint(x: 0, y: 0), to: CGPoint(x: 0, y: size))

// Base, set back and a little right, under the monitor's middle
let base = CGRect(x: 548 - 200, y: 790, width: 400, height: 86)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 30, color: rgb(0x5A4A2A, 0.4))
ctx.setFillColor(rgb(0x1C1E22))
ctx.fillEllipse(in: base)
ctx.restoreGState()
clipped(CGPath(ellipseIn: base, transform: nil)) {
    linear([rgb(0x454953), rgb(0x16181C)], from: CGPoint(x: 0, y: base.minY), to: CGPoint(x: 0, y: base.maxY))
}
ctx.setFillColor(rgb(0x2C2F35))
ctx.fillEllipse(in: base.insetBy(dx: 44, dy: 16).offsetBy(dx: 0, dy: -4))

// Neck, rising from the base into the back of the monitor
let neck = polygon([CGPoint(x: 520, y: 600), CGPoint(x: 568, y: 597), CGPoint(x: 584, y: 836), CGPoint(x: 506, y: 838)])
clipped(neck) {
    linear([rgb(0x15171B), rgb(0x3E424B), rgb(0x15171B)], from: CGPoint(x: 506, y: 0), to: CGPoint(x: 584, y: 0))
}

drawWarped(back, to: backQuad, shadow: 40)
drawWarped(face, to: [tl, tr, br, bl])

// MARK: Write

let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
