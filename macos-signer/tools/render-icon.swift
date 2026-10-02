import AppKit
import CoreText

// Native vector/text rendering keeps the two Chinese glyphs precise at every size.
guard CommandLine.arguments.count == 2 else { fatalError("Usage: render-icon.swift AssetsDirectory") }
let assets = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let iconset = assets.appendingPathComponent("RenewIcon.iconset", isDirectory: true)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func render(pixels: Int, to url: URL) throws {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                  isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let graphics = NSGraphicsContext(bitmapImageRep: bitmap)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = graphics
    let context = graphics.cgContext
    context.setShouldAntialias(true)
    context.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
    NSColor(calibratedRed: 0.39, green: 0.90, blue: 0.79, alpha: 1).setFill()
    NSBezierPath(roundedRect: NSRect(x: 64, y: 64, width: 896, height: 896), xRadius: 198, yRadius: 198).fill()
    let text = NSAttributedString(string: "续签", attributes: [
        NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("PingFangSC-Semibold" as CFString, 352, nil),
        NSAttributedString.Key(kCTForegroundColorAttributeName as String): NSColor(calibratedRed: 0.055, green: 0.13, blue: 0.15, alpha: 1).cgColor
    ])
    let line = CTLineCreateWithAttributedString(text)
    let ink = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
    context.textPosition = CGPoint(x: (1024 - ink.width) / 2 - ink.minX,
                                   y: (1024 - ink.height) / 2 - ink.minY)
    CTLineDraw(line, context)
    NSGraphicsContext.restoreGraphicsState()
    try bitmap.representation(using: .png, properties: [:])!.write(to: url, options: .atomic)
}

for points in [16, 32, 128, 256, 512] {
    try render(pixels: points, to: iconset.appendingPathComponent("icon_\(points)x\(points).png"))
    try render(pixels: points * 2, to: iconset.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
}
try render(pixels: 1024, to: assets.appendingPathComponent("RenewIcon-preview.png"))
