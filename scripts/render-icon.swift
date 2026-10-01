// Renders the app icon variants into the asset catalog:
//   for v in light dark tinted; do swift scripts/render-icon.swift $v \
//     SuperSynch/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-$v.png; done
// Drawn with CoreGraphics (SF Symbols may not be used in app icons).

import AppKit
import CoreGraphics

// Renders the SuperSynch app icon (1024×1024, no transparency for the default).
// Variant: "light" (blue gradient), "dark" (near-black, blue glyph), "tinted"
// (grayscale glyph on transparent, for iOS 18 tinted icons).
let variant = CommandLine.arguments[1]
let out = CommandLine.arguments[2]
let size = 1024
let cs = CGColorSpaceCreateDeviceRGB()
let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                    space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
let S = CGFloat(size)
// Flip to top-left origin for easier reasoning.
ctx.translateBy(x: 0, y: S); ctx.scaleBy(x: 1, y: -1)

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor { CGColor(red: r/255, green: g/255, blue: b/255, alpha: a) }

// Background
switch variant {
case "light":
    let g = CGGradient(colorsSpace: cs, colors: [rgb(38, 177, 245), rgb(1, 136, 208), rgb(0, 92, 160)] as CFArray, locations: [0, 0.55, 1])!
    ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: 0), end: CGPoint(x: S, y: S), options: [])
    // soft top highlight
    let h = CGGradient(colorsSpace: cs, colors: [rgb(255, 255, 255, 0.18), rgb(255, 255, 255, 0)] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(h, startCenter: CGPoint(x: S*0.3, y: S*0.15), startRadius: 0, endCenter: CGPoint(x: S*0.3, y: S*0.15), endRadius: S*0.75, options: [])
case "dark":
    let g = CGGradient(colorsSpace: cs, colors: [rgb(26, 32, 40), rgb(10, 12, 16)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 0, y: S), options: [])
default:
    break // tinted: transparent
}

let glyph: CGColor
let phoneFill: CGColor
switch variant {
case "light": glyph = rgb(255, 255, 255); phoneFill = rgb(255, 255, 255, 0.16)
case "dark": glyph = rgb(72, 176, 240); phoneFill = rgb(72, 176, 240, 0.14)
default: glyph = rgb(255, 255, 255); phoneFill = rgb(255, 255, 255, 0.25)
}

let c = CGPoint(x: S/2, y: S/2)
// Keep the glyph inside the icon's safe area (iOS masks the corners).
ctx.translateBy(x: c.x, y: c.y); ctx.scaleBy(x: 0.86, y: 0.86); ctx.translateBy(x: -c.x, y: -c.y)
let R: CGFloat = 318          // loop radius
let stroke: CGFloat = 74

// Two arcs of the sync loop, each with an arrowhead.
func arc(from a0: CGFloat, to a1: CGFloat) {
    ctx.setStrokeColor(glyph)
    ctx.setLineWidth(stroke)
    ctx.setLineCap(.round)
    ctx.addArc(center: c, radius: R, startAngle: a0, endAngle: a1, clockwise: false)
    ctx.strokePath()
    // Arrowhead at a1, pointing along the direction of travel (increasing angle).
    let tip = CGPoint(x: c.x + R * cos(a1), y: c.y + R * sin(a1))
    let tangent = CGPoint(x: -sin(a1), y: cos(a1))          // direction of increasing angle
    let normal = CGPoint(x: cos(a1), y: sin(a1))
    let len: CGFloat = 150, half: CGFloat = 104
    let front = CGPoint(x: tip.x + tangent.x * len * 0.62, y: tip.y + tangent.y * len * 0.62)
    let back = CGPoint(x: tip.x - tangent.x * len * 0.38, y: tip.y - tangent.y * len * 0.38)
    let p1 = CGPoint(x: back.x + normal.x * half, y: back.y + normal.y * half)
    let p2 = CGPoint(x: back.x - normal.x * half, y: back.y - normal.y * half)
    ctx.setFillColor(glyph)
    ctx.setLineJoin(.round)
    ctx.move(to: front); ctx.addLine(to: p1); ctx.addLine(to: p2); ctx.closePath()
    ctx.setLineWidth(18); ctx.setStrokeColor(glyph)
    ctx.drawPath(using: .fillStroke)
}
let deg = CGFloat.pi / 180
arc(from: 200 * deg, to: 318 * deg)   // upper arc, clockwise on screen
arc(from: 20 * deg, to: 138 * deg)    // lower arc

// Phone in the middle.
let pw: CGFloat = 214, ph: CGFloat = 372
let phone = CGRect(x: c.x - pw/2, y: c.y - ph/2, width: pw, height: ph)
let path = CGPath(roundedRect: phone, cornerWidth: 52, cornerHeight: 52, transform: nil)
ctx.addPath(path); ctx.setFillColor(phoneFill); ctx.fillPath()
ctx.addPath(path); ctx.setStrokeColor(glyph); ctx.setLineWidth(30); ctx.strokePath()
// Dynamic Island
let island = CGRect(x: c.x - 40, y: phone.minY + 34, width: 80, height: 22)
ctx.addPath(CGPath(roundedRect: island, cornerWidth: 11, cornerHeight: 11, transform: nil))
ctx.setFillColor(glyph); ctx.fillPath()
// Two "file" lines
ctx.setStrokeColor(glyph); ctx.setLineCap(.round); ctx.setLineWidth(22)
for (i, w) in [CGFloat(110), 76].enumerated() {
    let y = c.y + 18 + CGFloat(i) * 52
    ctx.move(to: CGPoint(x: c.x - 55, y: y)); ctx.addLine(to: CGPoint(x: c.x - 55 + w, y: y))
}
ctx.strokePath()

var image = ctx.makeImage()!
if variant != "tinted" {
    // App icons must be opaque: re-render without an alpha channel.
    let opaque = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                           bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    opaque.draw(image, in: CGRect(x: 0, y: 0, width: S, height: S))
    image = opaque.makeImage()!
}
if variant == "tinted" {
    // Tinted icons are grayscale; iOS applies the tint.
    let gray = CGColorSpaceCreateDeviceGray()
    let g = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: gray,
                      bitmapInfo: CGImageAlphaInfo.none.rawValue)!
    g.setFillColor(gray: 0, alpha: 1); g.fill(CGRect(x: 0, y: 0, width: S, height: S))
    g.draw(image, in: CGRect(x: 0, y: 0, width: S, height: S))
    image = g.makeImage()!
}
let rep = NSBitmapImageRep(cgImage: image)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
