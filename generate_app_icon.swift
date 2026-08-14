import AppKit

guard CommandLine.arguments.count == 2 else {
    fputs("usage: generate_app_icon.swift <output.png>\n", stderr)
    exit(2)
}

let size = 1024
guard let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: size,
    pixelsHigh: size,
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
) else {
    fatalError("Unable to create icon bitmap")
}

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
NSGraphicsContext.current?.imageInterpolation = .high

let canvas = NSRect(x: 0, y: 0, width: size, height: size)
NSColor.clear.setFill()
canvas.fill()

let backgroundRect = NSRect(x: 64, y: 64, width: 896, height: 896)
let background = NSBezierPath(roundedRect: backgroundRect, xRadius: 210, yRadius: 210)
let backgroundGradient = NSGradient(colors: [
    NSColor(calibratedRed: 0.29, green: 0.59, blue: 0.98, alpha: 1),
    NSColor(calibratedRed: 0.10, green: 0.31, blue: 0.76, alpha: 1),
])!
backgroundGradient.draw(in: background, angle: 90)

let glow = NSBezierPath(ovalIn: NSRect(x: 138, y: 590, width: 748, height: 310))
NSColor(calibratedWhite: 1, alpha: 0.10).setFill()
glow.fill()

let remoteRect = NSRect(x: 330, y: 132, width: 364, height: 760)
let remote = NSBezierPath(roundedRect: remoteRect, xRadius: 142, yRadius: 142)
NSGraphicsContext.saveGraphicsState()
let shadow = NSShadow()
shadow.shadowColor = NSColor(calibratedWhite: 0, alpha: 0.34)
shadow.shadowBlurRadius = 34
shadow.shadowOffset = NSSize(width: 0, height: -18)
shadow.set()
NSColor(calibratedWhite: 0.97, alpha: 1).setFill()
remote.fill()
NSGraphicsContext.restoreGraphicsState()

remote.lineWidth = 8
NSColor(calibratedWhite: 1, alpha: 0.68).setStroke()
remote.stroke()

let controlRing = NSBezierPath(ovalIn: NSRect(x: 382, y: 548, width: 260, height: 260))
NSColor(calibratedRed: 0.07, green: 0.10, blue: 0.17, alpha: 1).setFill()
controlRing.fill()

let controlCenter = NSBezierPath(ovalIn: NSRect(x: 434, y: 600, width: 156, height: 156))
NSColor(calibratedRed: 0.23, green: 0.29, blue: 0.40, alpha: 1).setFill()
controlCenter.fill()

let powerButton = NSBezierPath(ovalIn: NSRect(x: 462, y: 470, width: 100, height: 100))
NSColor(calibratedRed: 0.95, green: 0.28, blue: 0.31, alpha: 1).setFill()
powerButton.fill()

let micButton = NSBezierPath(roundedRect: NSRect(x: 414, y: 350, width: 196, height: 82), xRadius: 41, yRadius: 41)
NSColor(calibratedRed: 0.16, green: 0.40, blue: 0.86, alpha: 1).setFill()
micButton.fill()

let micCapsule = NSBezierPath(roundedRect: NSRect(x: 492, y: 370, width: 40, height: 38), xRadius: 20, yRadius: 20)
NSColor.white.setFill()
micCapsule.fill()
let micStem = NSBezierPath()
micStem.move(to: NSPoint(x: 512, y: 370))
micStem.line(to: NSPoint(x: 512, y: 358))
micStem.lineWidth = 9
micStem.lineCapStyle = .round
NSColor.white.setStroke()
micStem.stroke()

for centerX in [438.0, 512.0, 586.0] {
    let button = NSBezierPath(ovalIn: NSRect(x: centerX - 24, y: 250, width: 48, height: 48))
    NSColor(calibratedRed: 0.16, green: 0.20, blue: 0.29, alpha: 1).setFill()
    button.fill()
}

let speaker = NSBezierPath(roundedRect: NSRect(x: 456, y: 196, width: 112, height: 18), xRadius: 9, yRadius: 9)
NSColor(calibratedWhite: 0.20, alpha: 0.58).setFill()
speaker.fill()

NSGraphicsContext.restoreGraphicsState()

guard let png = bitmap.representation(using: .png, properties: [:]) else {
    fatalError("Unable to encode icon PNG")
}
try png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
