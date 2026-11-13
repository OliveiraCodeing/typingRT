// Project tool: draws the typingRT app icon and writes an .iconset folder.
// Usage: swift scripts/make-icon.swift <output.iconset>
// The motif mirrors the idle overlay: a dark disc with a light dot, flanked
// by the violet level bars shown while dictating.
import AppKit

func draw(size: Int) -> Data {
    let s = CGFloat(size)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = context
    let g = context.cgContext
    func color(_ r: CGFloat, _ gr: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
        CGColor(red: r / 255, green: gr / 255, blue: b / 255, alpha: a)
    }
    // macOS icon grid: 824 pt body on a 1024 pt canvas.
    let inset = s * 100 / 1024
    let body = CGRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let shape = CGPath(roundedRect: body, cornerWidth: body.width * 0.2237, cornerHeight: body.width * 0.2237, transform: nil)
    g.saveGState()
    g.setShadow(offset: CGSize(width: 0, height: -s * 0.012), blur: s * 0.03, color: color(0, 0, 0, 0.45))
    g.addPath(shape)
    g.setFillColor(color(18, 20, 22))
    g.fillPath()
    g.restoreGState()
    g.saveGState()
    g.addPath(shape)
    g.clip()
    let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                              colors: [color(42, 46, 54), color(14, 15, 18)] as CFArray, locations: [0, 1])!
    g.drawLinearGradient(gradient, start: CGPoint(x: body.midX, y: body.maxY), end: CGPoint(x: body.midX, y: body.minY), options: [])
    g.restoreGState()
    g.addPath(shape)
    g.setStrokeColor(color(255, 255, 255, 0.10))
    g.setLineWidth(max(1, s * 0.004))
    g.strokePath()

    let center = CGPoint(x: body.midX, y: body.midY)
    // Level bars left and right of the disc.
    let barWidth = body.width * 0.052
    let gap = body.width * 0.046
    let heights: [CGFloat] = [0.30, 0.19, 0.10]
    let discRadius = body.width * 0.155
    for (index, height) in heights.enumerated() {
        let offset = discRadius + gap + barWidth / 2 + CGFloat(index) * (barWidth + gap)
        for direction in [CGFloat(-1), 1] {
            let h = body.height * height
            let rect = CGRect(x: center.x + direction * offset - barWidth / 2, y: center.y - h / 2, width: barWidth, height: h)
            g.addPath(CGPath(roundedRect: rect, cornerWidth: barWidth / 2, cornerHeight: barWidth / 2, transform: nil))
            g.setFillColor(color(167, 154, 255, 1 - CGFloat(index) * 0.22))
            g.fillPath()
        }
    }
    // Disc with dot: the idle overlay.
    g.setFillColor(color(8, 9, 11))
    g.fillEllipse(in: CGRect(x: center.x - discRadius, y: center.y - discRadius, width: discRadius * 2, height: discRadius * 2))
    g.setStrokeColor(color(255, 255, 255, 0.14))
    g.setLineWidth(max(1, s * 0.005))
    g.strokeEllipse(in: CGRect(x: center.x - discRadius, y: center.y - discRadius, width: discRadius * 2, height: discRadius * 2))
    let dot = discRadius * 0.36
    g.setFillColor(color(242, 244, 247))
    g.fillEllipse(in: CGRect(x: center.x - dot, y: center.y - dot, width: dot * 2, height: dot * 2))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("Usage: swift scripts/make-icon.swift <output.iconset>\n".utf8))
    exit(1)
}
let output = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
for (points, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)] {
    let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
    try draw(size: points * scale).write(to: output.appendingPathComponent(name))
}
