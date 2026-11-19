import AppKit
import SwiftUI

private let space = CGColorSpace(name: CGColorSpace.sRGB)!
private func color(_ rgb: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((rgb >> 16) & 255) / 255, green: CGFloat((rgb >> 8) & 255) / 255,
            blue: CGFloat(rgb & 255) / 255, alpha: alpha)
}
private func box(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat) -> CGPath {
    CGPath(roundedRect: CGRect(x: x, y: y, width: w, height: h), cornerWidth: r, cornerHeight: r, transform: nil)
}
private func fill(_ c: CGContext, _ shape: CGPath, _ rgb: UInt32, _ alpha: CGFloat = 1) {
    c.setFillColor(color(rgb, alpha)); c.addPath(shape); c.fillPath()
}
private func edge(_ c: CGContext, _ shape: CGPath, _ rgb: UInt32, _ width: CGFloat, _ alpha: CGFloat = 1) {
    c.setStrokeColor(color(rgb, alpha)); c.setLineWidth(width); c.setLineJoin(.round); c.addPath(shape); c.strokePath()
}
private func gradient(_ c: CGContext, _ shape: CGPath, _ top: UInt32, _ bottom: UInt32) {
    c.saveGState(); c.addPath(shape); c.clip()
    let bounds = shape.boundingBoxOfPath
    let g = CGGradient(colorsSpace: space, colors: [color(top), color(bottom)] as CFArray, locations: [0, 1])!
    c.drawLinearGradient(g, start: CGPoint(x: 0, y: bounds.minY), end: CGPoint(x: 0, y: bounds.maxY), options: [])
    c.restoreGState()
}
private func drawPointer(_ c: CGContext) {
    let p = CGMutablePath()
    let outline: [(CGFloat, CGFloat)] = [(78,46),(309,279),(218,279),(260,380),(187,410),(143,305),(78,365)]
    p.addLines(between: outline.map { CGPoint(x: 672 - (309 - $0.0) * 1.18, y: 231 + ($0.1 - 46) * 1.18) })
    p.closeSubpath()
    c.saveGState(); c.translateBy(x: 0, y: 12)
    edge(c, p, 0x05080E, 21, 0.45); fill(c, p, 0x05080E, 0.60)
    c.restoreGState()
    edge(c, p, 0xE8EFFF, 12); gradient(c, p, 0xFFFFFF, 0xCCDCF9)
}
private func drawKey(_ c: CGContext, _ x: CGFloat, _ width: CGFloat, spacebar: Bool = false) {
    fill(c, box(x - 4, 719, width + 8, 77, 20), 0x0A0D16, 0.72)
    fill(c, box(x, 725, width, 64, 17), spacebar ? 0x426CB0 : 0x4F6282)
    gradient(c, box(x, 712, width, 64, 17), spacebar ? 0xAACDFF : 0xB6C4DC, spacebar ? 0x77A8FF : 0x8D9FBF)
    edge(c, box(x + 1.5, 713.5, width - 3, 61, 16), spacebar ? 0xF1F7FF : 0xEBF3FF, 3, 0.38)
}
private func render(_ size: Int) -> Data {
    // Render the approved 1024 px master, then downsample for clean small-size edges.
    let master = CGContext(data: nil, width: 1024, height: 1024, bitsPerComponent: 8, bytesPerRow: 0,
                           space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    master.translateBy(x: 0, y: 1024); master.scaleBy(x: 1, y: -1)
    // macOS grid: 824 px squircle centred in a 1024 px canvas.
    let tile = RoundedRectangle(cornerRadius: 185, style: .continuous)
        .path(in: CGRect(x: 100, y: 100, width: 824, height: 824)).cgPath
    master.saveGState(); master.addPath(tile); master.clip()
    gradient(master, tile, 0x252B37, 0x171A22); edge(master, tile, 0x798CAB, 5, 0.30)
    master.restoreGState()
    drawPointer(master)
    drawKey(master, 244, 114); drawKey(master, 381, 262, spacebar: true); drawKey(master, 666, 114)
    let source = master.makeImage()!
    if size == 1024 { return NSBitmapImageRep(cgImage: source).representation(using: .png, properties: [:])! }
    let bitmap = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                           space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    bitmap.interpolationQuality = .high; bitmap.draw(source, in: CGRect(x: 0, y: 0, width: size, height: size))
    return NSBitmapImageRep(cgImage: bitmap.makeImage()!).representation(using: .png, properties: [:])!
}

let destination = CommandLine.arguments[1]
let temporary = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("GestureKeys-\(UUID().uuidString).iconset")
try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: temporary) }
let names = [16:["icon_16x16"], 32:["icon_16x16@2x","icon_32x32"], 64:["icon_32x32@2x"],
             128:["icon_128x128"], 256:["icon_128x128@2x","icon_256x256"], 512:["icon_256x256@2x","icon_512x512"], 1024:["icon_512x512@2x"]]
for size in names.keys.sorted() {
    let data = render(size)
    for name in names[size]! { try data.write(to: temporary.appendingPathComponent(name + ".png")) }
}
let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", temporary.path, "-o", destination]
try process.run(); process.waitUntilExit()
if process.terminationStatus != 0 { exit(process.terminationStatus) }
