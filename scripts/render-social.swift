import AppKit

// Run from the repository root on macOS: swift scripts/render-social.swift
// Uses the same native font, colours and calendar screenshot as the website hero.
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let output = root.appendingPathComponent("website/public/social/calibar-hero.png")
let canvas = NSSize(width: 1200, height: 630)
let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1200, pixelsHigh: 630,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
NSGraphicsContext.current?.imageInterpolation = .high
NSColor.white.setFill()
NSRect(origin: .zero, size: canvas).fill()

let ink = NSColor(srgbRed: 29/255, green: 29/255, blue: 31/255, alpha: 1)
let red = NSColor(srgbRed: 1, green: 56/255, blue: 60/255, alpha: 1)
let grey = NSColor(srgbRed: 110/255, green: 110/255, blue: 115/255, alpha: 1)
func label(_ text: String, top: CGFloat, size: CGFloat, weight: NSFont.Weight,
           color: NSColor, tracking: CGFloat = 0) {
    let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: size, weight: weight),
        .foregroundColor: color, .kern: tracking
    ]
    let height = size * 1.4
    (text as NSString).draw(in: NSRect(x: 64, y: canvas.height - top - height,
        width: 720, height: height), withAttributes: attributes)
}
label("CaliBar", top: 67, size: 30, weight: .semibold, color: ink, tracking: -1.2)
label("Your calendar.", top: 193, size: 68, weight: .semibold, color: ink, tracking: -1.02)
label("Always in reach.", top: 266, size: 68, weight: .semibold, color: red, tracking: -1.02)
label("A native companion to Apple Calendar.", top: 376, size: 25, weight: .regular, color: grey)
label("Free. Built for Mac.", top: 414, size: 25, weight: .regular, color: grey)
label("calibar.app", top: 538, size: 19, weight: .medium, color: ink)

let screenshot = NSImage(contentsOf: root.appendingPathComponent("website/public/screenshots/calendar.png"))!
let frame = NSRect(x: 822, y: 46, width: 310, height: 538)
let outline = NSBezierPath(roundedRect: frame, xRadius: 21, yRadius: 21)
NSGraphicsContext.saveGraphicsState()
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.15)
shadow.shadowBlurRadius = 32
shadow.shadowOffset = NSSize(width: 0, height: -12)
shadow.set()
NSColor.white.setFill()
outline.fill()
NSGraphicsContext.restoreGraphicsState()
NSGraphicsContext.saveGraphicsState()
outline.addClip()
screenshot.draw(in: frame)
NSGraphicsContext.restoreGraphicsState()
NSGraphicsContext.current = nil
try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
try bitmap.representation(using: .png, properties: [:])!.write(to: output)
print(output.path)
