// アプリアイコンを生成する。macOS の角丸(1024 キャンバスに 824 の角丸正方形)に、
// メニューバーと同じ「トレイ」のモチーフを置く。
// 使い方: swift scripts/make-app-icon.swift TaskApp/Assets.xcassets/AppIcon.appiconset
import AppKit

let outDir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.appiconset")
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

func render(_ size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    defer { image.unlockFocus() }
    let s = size / 1024
    let inset = 100 * s
    let rect = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let path = NSBezierPath(roundedRect: rect, xRadius: 185 * s, yRadius: 185 * s)

    // 背景: 深い藍から青へ。引き出しの「中」を感じさせる落ち着いた色。
    let gradient = NSGradient(colors: [
        NSColor(calibratedRed: 0.13, green: 0.22, blue: 0.48, alpha: 1),
        NSColor(calibratedRed: 0.25, green: 0.47, blue: 0.86, alpha: 1),
    ])!
    gradient.draw(in: path, angle: 90)

    // 引き出し本体: 下 2/3 に箱、前板に取っ手。上に飛び出す紙(タスク)を 3 枚。
    let w = rect.width
    let boxRect = NSRect(x: rect.minX + w * 0.16, y: rect.minY + w * 0.17, width: w * 0.68, height: w * 0.40)
    let box = NSBezierPath(roundedRect: boxRect, xRadius: 36 * s, yRadius: 36 * s)
    NSColor(calibratedWhite: 1, alpha: 0.96).setFill()
    box.fill()
    // 前板の影線
    let lip = NSBezierPath(roundedRect: NSRect(x: boxRect.minX, y: boxRect.maxY - w * 0.055, width: boxRect.width, height: w * 0.055), xRadius: 20 * s, yRadius: 20 * s)
    NSColor(calibratedRed: 0.13, green: 0.22, blue: 0.48, alpha: 0.18).setFill()
    lip.fill()
    // 取っ手
    let handle = NSBezierPath(roundedRect: NSRect(x: boxRect.midX - w * 0.09, y: boxRect.minY + w * 0.15, width: w * 0.18, height: w * 0.045), xRadius: 24 * s, yRadius: 24 * s)
    NSColor(calibratedRed: 0.13, green: 0.22, blue: 0.48, alpha: 0.9).setFill()
    handle.fill()

    // 紙 3 枚: 今日(青)・期限あり(橙)・スプリント(紫)の色で、タイプを示す。
    let colors = [
        NSColor(calibratedRed: 1.0, green: 0.62, blue: 0.25, alpha: 1),   // 橙
        NSColor(calibratedRed: 0.62, green: 0.52, blue: 0.95, alpha: 1),  // 紫
        NSColor(calibratedRed: 0.55, green: 0.80, blue: 1.0, alpha: 1),   // 水色
    ]
    let paperW = w * 0.17, paperH = w * 0.30
    let startX = boxRect.minX + w * 0.085
    for (i, color) in colors.enumerated() {
        let x = startX + CGFloat(i) * (paperW + w * 0.075)
        let y = boxRect.maxY - w * 0.10 + CGFloat(i % 2) * w * 0.03
        let paper = NSBezierPath(roundedRect: NSRect(x: x, y: y, width: paperW, height: paperH), xRadius: 18 * s, yRadius: 18 * s)
        color.setFill()
        paper.fill()
        // チェックマーク風の短い線
        NSColor(calibratedWhite: 1, alpha: 0.85).setStroke()
        let line = NSBezierPath()
        line.lineWidth = 16 * s
        line.lineCapStyle = .round
        line.move(to: NSPoint(x: x + paperW * 0.25, y: y + paperH * 0.72))
        line.line(to: NSPoint(x: x + paperW * 0.75, y: y + paperH * 0.72))
        line.stroke()
    }
    return image
}

func write(_ image: NSImage, to url: URL, pixels: Int) {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: url)
}

let sizes: [(Int, Int)] = [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)]
var images: [[String: String]] = []
for (pt, scale) in sizes {
    let px = pt * scale
    let name = "icon_\(pt)x\(pt)\(scale == 2 ? "@2x" : "").png"
    write(render(CGFloat(px)), to: outDir.appendingPathComponent(name), pixels: px)
    images.append(["size": "\(pt)x\(pt)", "idiom": "mac", "filename": name, "scale": "\(scale)x"])
}
let contents: [String: Any] = ["images": images, "info": ["version": 1, "author": "xcode"]]
let data = try! JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
try! data.write(to: outDir.appendingPathComponent("Contents.json"))
print("wrote \(images.count) images to \(outDir.path)")
