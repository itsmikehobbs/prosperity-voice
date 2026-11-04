// Draws the app icon: navy rounded square, yellow voice bars, red dot. Usage: swift make-icon.swift out.png
import AppKit
let size: CGFloat = 1024
let img = NSImage(size: NSSize(width: size, height: size))
img.lockFocus()
let ctx = NSGraphicsContext.current!.cgContext
let inset: CGFloat = 100
let rect = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
let path = CGPath(roundedRect: rect, cornerWidth: 185, cornerHeight: 185, transform: nil)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 30, color: NSColor.black.withAlphaComponent(0.35).cgColor)
ctx.addPath(path); ctx.setFillColor(NSColor(red: 10/255, green: 25/255, blue: 41/255, alpha: 1).cgColor); ctx.fillPath()
ctx.restoreGState()
ctx.saveGState(); ctx.addPath(path); ctx.clip()
let colors = [NSColor(red: 21/255, green: 44/255, blue: 66/255, alpha: 1).cgColor, NSColor(red: 10/255, green: 25/255, blue: 41/255, alpha: 1).cgColor] as CFArray
let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: size - inset), end: CGPoint(x: 0, y: inset), options: [])
ctx.restoreGState()
let heights: [CGFloat] = [150, 290, 440, 330, 520, 360, 230, 130]
let barW: CGFloat = 50, gap: CGFloat = 30
let total = CGFloat(heights.count) * barW + CGFloat(heights.count - 1) * gap
var x = (size - total) / 2
let yellow = NSColor(red: 1, green: 214/255, blue: 10/255, alpha: 1)
for h in heights {
    let r = CGRect(x: x, y: size / 2 - h / 2 - 10, width: barW, height: h)
    ctx.addPath(CGPath(roundedRect: r, cornerWidth: barW / 2, cornerHeight: barW / 2, transform: nil))
    ctx.setFillColor(yellow.cgColor); ctx.fillPath()
    x += barW + gap
}
ctx.setFillColor(NSColor(red: 230/255, green: 57/255, blue: 70/255, alpha: 1).cgColor)
ctx.fillEllipse(in: CGRect(x: size - inset - 190, y: size - inset - 190, width: 90, height: 90))
img.unlockFocus()
let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
