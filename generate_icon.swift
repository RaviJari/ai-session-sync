// ponytail: native icon generator — Core Graphics + SF Symbol, no image libs.
import Cocoa

let size = 1024
let img = NSImage(size: NSSize(width: size, height: size))
img.lockFocus()

let ctx = NSGraphicsContext.current!.cgContext
let rect = CGRect(x: 0, y: 0, width: size, height: size)

// Rounded-square base, macOS Big Sur-style continuous corner, violet→blue gradient
let corner = CGFloat(size) * 0.225
let path = NSBezierPath(roundedRect: rect, xRadius: corner, yRadius: corner)
path.addClip()

let colors = [
    NSColor(calibratedRed: 0.42, green: 0.27, blue: 0.96, alpha: 1).cgColor,
    NSColor(calibratedRed: 0.23, green: 0.56, blue: 0.98, alpha: 1).cgColor,
]
let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(gradient,
                        start: CGPoint(x: 0, y: size), end: CGPoint(x: size, y: 0),
                        options: [])

// Sync glyph (SF Symbol), white, centered
let symbolSize = CGFloat(size) * 0.52
let config = NSImage.SymbolConfiguration(pointSize: symbolSize, weight: .semibold)
if let symbol = NSImage(systemSymbolName: "arrow.triangle.2.circlepath", accessibilityDescription: nil)?
    .withSymbolConfiguration(config) {
    let tinted = symbol.copy() as! NSImage
    tinted.lockFocus()
    NSColor.white.set()
    NSRect(origin: .zero, size: tinted.size).fill(using: .sourceAtop)
    tinted.unlockFocus()
    let drawRect = CGRect(x: (CGFloat(size) - tinted.size.width) / 2,
                           y: (CGFloat(size) - tinted.size.height) / 2,
                           width: tinted.size.width, height: tinted.size.height)
    tinted.draw(in: drawRect)
}

img.unlockFocus()

guard let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    fatalError("render failed")
}
let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon-1024.png"
try! png.write(to: URL(fileURLWithPath: outPath))
print("wrote \(outPath)")
