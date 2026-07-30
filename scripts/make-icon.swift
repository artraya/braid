// Generates AppIcon.icns for ms-notes. Run via scripts/make-icon.sh.
// Draws every size natively rather than downscaling one master, so the small
// sizes stay crisp. Concept: a waveform resolving into written lines, which is
// exactly what the app does to a meeting.
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let sizes = [16, 32, 64, 128, 256, 512, 1024]
let outputDir = URL(fileURLWithPath: CommandLine.arguments.count > 1
                    ? CommandLine.arguments[1] : "./AppIcon.iconset")
try? FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

/// Squircle-ish rounded rect matching the macOS app-icon silhouette.
func roundedRect(_ rect: CGRect, radius: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

func drawIcon(size: Int) -> CGImage? {
    let s = CGFloat(size)
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(data: nil, width: size, height: size,
                              bitsPerComponent: 8, bytesPerRow: 0,
                              space: colorSpace,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }
    ctx.setAllowsAntialiasing(true)
    ctx.interpolationQuality = .high

    // Canvas inset: macOS icons sit inside their 1024 canvas with breathing room.
    let inset = s * 0.09
    let body = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let radius = body.width * 0.2237

    // Background gradient: deep indigo to a warmer violet, top-left to bottom-right.
    ctx.saveGState()
    ctx.addPath(roundedRect(body, radius: radius))
    ctx.clip()
    let gradient = CGGradient(colorsSpace: colorSpace,
        colors: [
            CGColor(red: 0.24, green: 0.29, blue: 0.62, alpha: 1),  // indigo
            CGColor(red: 0.42, green: 0.28, blue: 0.68, alpha: 1),  // violet
        ] as CFArray,
        locations: [0, 1])!
    ctx.drawLinearGradient(gradient,
        start: CGPoint(x: body.minX, y: body.maxY),
        end: CGPoint(x: body.maxX, y: body.minY),
        options: [])

    // Soft highlight across the top edge, so the face is not flat.
    let sheen = CGGradient(colorsSpace: colorSpace,
        colors: [
            CGColor(red: 1, green: 1, blue: 1, alpha: 0.18),
            CGColor(red: 1, green: 1, blue: 1, alpha: 0),
        ] as CFArray,
        locations: [0, 1])!
    ctx.drawLinearGradient(sheen,
        start: CGPoint(x: body.midX, y: body.maxY),
        end: CGPoint(x: body.midX, y: body.midY),
        options: [])
    ctx.restoreGState()

    // --- Foreground: waveform above, note lines below ---
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))

    // Below 64pt there is not enough room for five bars and three lines to stay
    // legible, so the artwork simplifies rather than turning to mush.
    let small = size <= 64

    let contentWidth = body.width * (small ? 0.60 : 0.56)
    let contentX = body.midX - contentWidth / 2

    // Waveform: bars symmetric about the centre, tallest in the middle.
    let barHeights: [CGFloat] = small ? [0.45, 0.8, 1.0, 0.62] : [0.34, 0.62, 1.0, 0.72, 0.42]
    let barCount = CGFloat(barHeights.count)
    let barGap = contentWidth * (small ? 0.10 : 0.085)
    let barWidth = (contentWidth - barGap * (barCount - 1)) / barCount
    let maxBarHeight = body.height * (small ? 0.52 : 0.30)
    // Small sizes drop the note lines, so the waveform sits centred instead.
    let waveCentreY = small ? body.midY : body.midY + body.height * 0.10

    for (i, h) in barHeights.enumerated() {
        let height = max(maxBarHeight * h, barWidth)
        let x = contentX + (barWidth + barGap) * CGFloat(i)
        let rect = CGRect(x: x, y: waveCentreY - height / 2, width: barWidth, height: height)
        ctx.addPath(roundedRect(rect, radius: barWidth / 2))
        ctx.fillPath()
    }

    // Note lines: decreasing width, reading as written text. Omitted at small
    // sizes, where they would collapse into an illegible smudge.
    if !small {
        let lineHeight = barWidth * 0.72
        let lineGap = lineHeight * 1.5
        let lineWidths: [CGFloat] = [1.0, 0.82, 0.55]
        let firstLineY = body.midY - body.height * 0.13

        for (i, w) in lineWidths.enumerated() {
            let y = firstLineY - (lineHeight + lineGap) * CGFloat(i)
            let rect = CGRect(x: contentX, y: y, width: contentWidth * w, height: lineHeight)
            ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: i == 2 ? 0.72 : 0.95))
            ctx.addPath(roundedRect(rect, radius: lineHeight / 2))
            ctx.fillPath()
        }
    }

    return ctx.makeImage()
}

func write(_ image: CGImage, to url: URL) throws {
    guard let dest = CGImageDestinationCreateWithURL(
        url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        throw NSError(domain: "icon", code: 1)
    }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { throw NSError(domain: "icon", code: 2) }
}

// iconset naming: each logical size at 1x and 2x.
let iconsetNames: [(Int, String)] = [
    (16, "icon_16x16.png"), (32, "icon_16x16@2x.png"),
    (32, "icon_32x32.png"), (64, "icon_32x32@2x.png"),
    (128, "icon_128x128.png"), (256, "icon_128x128@2x.png"),
    (256, "icon_256x256.png"), (512, "icon_256x256@2x.png"),
    (512, "icon_512x512.png"), (1024, "icon_512x512@2x.png"),
]

var cache: [Int: CGImage] = [:]
for size in sizes {
    cache[size] = drawIcon(size: size)
}
for (size, name) in iconsetNames {
    guard let image = cache[size] else { continue }
    try write(image, to: outputDir.appendingPathComponent(name))
}
print("wrote \(iconsetNames.count) images to \(outputDir.path)")
