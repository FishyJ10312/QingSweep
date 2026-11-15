import AppKit
let destination = CommandLine.arguments[1]
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
NSColor(calibratedRed: 0.95, green: 0.96, blue: 0.92, alpha: 1).setFill()
NSBezierPath(roundedRect: NSRect(x: 38, y: 38, width: 948, height: 948), xRadius: 218, yRadius: 218).fill()
NSColor(calibratedRed: 0.16, green: 0.32, blue: 0.27, alpha: 1).setFill()
NSBezierPath(ovalIn: NSRect(x: 170, y: 170, width: 684, height: 684)).fill()
let leaf = NSBezierPath()
leaf.move(to: NSPoint(x: 358, y: 328))
leaf.curve(to: NSPoint(x: 720, y: 727), controlPoint1: NSPoint(x: 267, y: 624), controlPoint2: NSPoint(x: 544, y: 671))
leaf.curve(to: NSPoint(x: 358, y: 328), controlPoint1: NSPoint(x: 748, y: 451), controlPoint2: NSPoint(x: 569, y: 288))
NSColor(calibratedRed: 0.83, green: 0.89, blue: 0.69, alpha: 1).setFill()
leaf.fill()
let vein = NSBezierPath()
vein.move(to: NSPoint(x: 314, y: 283))
vein.curve(to: NSPoint(x: 622, y: 614), controlPoint1: NSPoint(x: 405, y: 413), controlPoint2: NSPoint(x: 488, y: 485))
vein.lineWidth = 25
vein.lineCapStyle = .round
NSColor(calibratedRed: 0.95, green: 0.96, blue: 0.92, alpha: 1).setStroke()
vein.stroke()
NSGraphicsContext.restoreGraphicsState()
try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: destination))
