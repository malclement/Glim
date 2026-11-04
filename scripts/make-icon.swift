// Renders Glim's artwork:
//
//   swift scripts/make-icon.swift <out>.iconset            the app icon, every size macOS uses
//   swift scripts/make-icon.swift --dmg-background <dir>   the DMG window background, 1x and 2x
//
// The icon comes from Support/AppIcon-source.png, the artwork as delivered: a
// rounded indigo tile with a glowing star, on an opaque black square. The tile
// is cut out of the black (an alpha channel derived from it, so the corners
// are transparent and the edge stays anti-aliased without a dark fringe) and
// placed on the macOS (Big Sur and later) app icon grid: a 1024 px canvas, the
// tile fitted into the 824 px square with a 100 px margin, and a soft drop
// shadow that falls into the margin. Each size is resampled from that.
//
// The DMG background is drawn with CoreGraphics.

import AppKit

// MARK: - Colour

let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: sRGB, components: [
        CGFloat((hex >> 16) & 0xFF) / 255,
        CGFloat((hex >> 8) & 0xFF) / 255,
        CGFloat(hex & 0xFF) / 255,
        alpha,
    ])!
}

func gradient(_ stops: [(CGFloat, CGColor)]) -> CGGradient {
    CGGradient(colorsSpace: sRGB, colors: stops.map(\.1) as CFArray, locations: stops.map(\.0))!
}

// MARK: - Canvas

/// A transparent sRGB bitmap of `pixels`, with a y-down coordinate system that
/// spans `units` across, so artwork is authored once in design units.
struct Canvas {
    let context: CGContext
    let scale: CGFloat  // device pixels per design unit

    init(width: Int, height: Int, units: CGFloat) {
        context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        scale = CGFloat(width) / units
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: 0, y: CGFloat(height) / scale)
        context.scaleBy(x: 1, y: -1)
    }

    /// Shadow offset and blur are in device space, so they are scaled here;
    /// a positive `y` drops the shadow below the shape.
    func shadow(y: CGFloat, blur: CGFloat, _ shadowColor: CGColor) {
        context.setShadow(offset: CGSize(width: 0, height: -y * scale), blur: blur * scale, color: shadowColor)
    }

    func fill(_ path: CGPath, _ fillColor: CGColor) {
        context.addPath(path)
        context.setFillColor(fillColor)
        context.fillPath()
    }

    /// Fills `path` with a gradient running from `from` to `to`.
    func fill(_ path: CGPath, _ g: CGGradient, from: CGPoint, to: CGPoint) {
        context.saveGState()
        context.addPath(path)
        context.clip()
        context.drawLinearGradient(g, start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        context.restoreGState()
    }

    func image() -> CGImage { context.makeImage()! }
}

// MARK: - App icon

/// The source artwork, next to this script's directory.
let sourceURL = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Support/AppIcon-source.png")

/// The tile of the source artwork as an image with an alpha channel, cropped
/// to the tile.
///
/// The black surround is found by flood-filling near-black pixels from the
/// image border, so nothing inside the tile can turn transparent however dark
/// it is (its darkest pixel is about 61/255). Pixels on the boundary are part
/// tile, part black: they get a partial alpha from their brightness, and their
/// colour is divided by it, which removes the dark fringe a plain mask leaves.
func extractTile(from url: URL) throws -> CGImage {
    guard let source = NSImage(contentsOf: url),
          let image = source.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
        throw NSError(domain: "make-icon", code: 2, userInfo: [NSLocalizedDescriptionKey: "cannot read \(url.path)"])
    }
    let width = image.width, height = image.height
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    let context = CGContext(
        data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
        space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

    func brightness(_ index: Int) -> Int {
        max(Int(pixels[index * 4]), Int(pixels[index * 4 + 1]), Int(pixels[index * 4 + 2]))
    }
    let backgroundLevel = 24  // the surround is at most 2/255; JPEG-like noise near the edge reaches 5
    let edgeLevel = 150.0     // the tile's rim is 170-200 just inside the edge

    // Flood fill the surround from every border pixel.
    var isBackground = [Bool](repeating: false, count: width * height)
    var stack: [Int] = []
    for x in 0..<width { stack += [x, (height - 1) * width + x] }
    for y in 0..<height { stack += [y * width, y * width + width - 1] }
    while let index = stack.popLast() {
        guard !isBackground[index], brightness(index) <= backgroundLevel else { continue }
        isBackground[index] = true
        let x = index % width, y = index / width
        if x > 0 { stack.append(index - 1) }
        if x < width - 1 { stack.append(index + 1) }
        if y > 0 { stack.append(index - width) }
        if y < height - 1 { stack.append(index + width) }
    }

    var minX = width, minY = height, maxX = -1, maxY = -1
    for y in 0..<height {
        for x in 0..<width {
            let index = y * width + x
            if isBackground[index] {
                pixels.replaceSubrange(index * 4..<index * 4 + 4, with: [0, 0, 0, 0])
                continue
            }
            minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            let touchesBackground = (x > 0 && isBackground[index - 1]) || (x < width - 1 && isBackground[index + 1])
                || (y > 0 && isBackground[index - width]) || (y < height - 1 && isBackground[index + width])
            guard touchesBackground else { continue }
            // The pixel is still premultiplied by black: keep it so, at a
            // partial alpha, which is exactly "colour divided by coverage".
            let alpha = min(1, Double(brightness(index)) / edgeLevel)
            pixels[index * 4 + 3] = UInt8((alpha * 255).rounded())
            for channel in 0..<3 {
                pixels[index * 4 + channel] = min(pixels[index * 4 + channel], pixels[index * 4 + 3])
            }
        }
    }
    guard maxX > minX, maxY > minY, let masked = context.makeImage(),
          let tile = masked.cropping(to: CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)) else {
        throw NSError(domain: "make-icon", code: 3, userInfo: [NSLocalizedDescriptionKey: "no tile found in \(url.path)"])
    }
    return tile
}

/// Draws the tile on the 1024-unit icon grid: fitted into the 824-unit
/// square, centred, with the template's drop shadow.
func drawIcon(_ canvas: Canvas, tile: CGImage) {
    let fit = 824 / CGFloat(max(tile.width, tile.height))
    let size = CGSize(width: CGFloat(tile.width) * fit, height: CGFloat(tile.height) * fit)
    let rect = CGRect(x: 512 - size.width / 2, y: 512 - size.height / 2, width: size.width, height: size.height)
    let ctx = canvas.context
    ctx.interpolationQuality = .high
    ctx.saveGState()
    canvas.shadow(y: 10, blur: 22, color(0x000000, 0.32))
    // The canvas is y-down; flip locally so the image draws upright.
    ctx.translateBy(x: 0, y: rect.maxY + rect.minY)
    ctx.scaleBy(x: 1, y: -1)
    ctx.draw(tile, in: rect)
    ctx.restoreGState()
}

// MARK: - DMG background

// Window content in points. Must match the layout in scripts/make-dmg.sh:
// icons are centred at (160, 196) and (480, 196). The image is taller than the
// 400 pt the window shows so that a title bar of any height never uncovers the
// plain window behind it.
let backgroundSize = CGSize(width: 640, height: 432)
let iconCentreY: CGFloat = 196

/// An indigo-to-violet gradient in the icon's colours, with an arrow from the
/// app to Applications. The tones stay mid-dark under the icon labels, where
/// Finder draws black text in Light Mode and white text in Dark Mode, so the
/// labels read in both.
func drawBackground(_ canvas: Canvas) {
    let ctx = canvas.context
    let all = CGPath(rect: CGRect(origin: .zero, size: backgroundSize), transform: nil)
    canvas.fill(all, gradient([(0, color(0x4B4592)), (1, color(0x8676BF))]), from: .zero, to: CGPoint(x: 0, y: backgroundSize.height))
    ctx.saveGState()
    ctx.addPath(all)
    ctx.clip()
    ctx.drawRadialGradient(
        gradient([(0, color(0xFF9FCF, 0.36)), (1, color(0xFF9FCF, 0))]),
        startCenter: CGPoint(x: 320, y: 470), startRadius: 0,
        endCenter: CGPoint(x: 320, y: 470), endRadius: 330, options: []
    )
    ctx.restoreGState()

    // Arrow between the two icons.
    let y = iconCentreY
    ctx.setStrokeColor(color(0xFFFFFF, 0.85))
    ctx.setLineWidth(4)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.move(to: CGPoint(x: 262, y: y))
    ctx.addLine(to: CGPoint(x: 376, y: y))
    ctx.move(to: CGPoint(x: 360, y: y - 16))
    ctx.addLine(to: CGPoint(x: 378, y: y))
    ctx.addLine(to: CGPoint(x: 360, y: y + 16))
    ctx.strokePath()
}

// MARK: - Output

func writePNG(_ image: CGImage, points: CGSize, to url: URL) throws {
    let rep = NSBitmapImageRep(cgImage: image)
    rep.size = NSSize(width: points.width, height: points.height)  // records 144 dpi for @2x
    guard let data = rep.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "make-icon", code: 1, userInfo: [NSLocalizedDescriptionKey: "PNG encoding failed for \(url.path)"])
    }
    try data.write(to: url, options: .atomic)
}

func makeIconset(at dir: URL) throws {
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let tile = try extractTile(from: sourceURL)
    for points in [16, 32, 128, 256, 512] {
        for factor in [1, 2] {
            let pixels = points * factor
            let canvas = Canvas(width: pixels, height: pixels, units: 1024)
            drawIcon(canvas, tile: tile)
            let name = factor == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
            try writePNG(canvas.image(), points: CGSize(width: points, height: points), to: dir.appendingPathComponent(name))
        }
    }
}

func makeBackground(in dir: URL) throws {
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    for factor in [1, 2] {
        let canvas = Canvas(
            width: Int(backgroundSize.width) * factor, height: Int(backgroundSize.height) * factor,
            units: backgroundSize.width
        )
        drawBackground(canvas)
        let name = factor == 1 ? "background.png" : "background@2x.png"
        try writePNG(canvas.image(), points: backgroundSize, to: dir.appendingPathComponent(name))
    }
}

// MARK: - Main

func fail(_ message: String, status: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data("make-icon: \(message)\n".utf8))
    exit(status)
}

let usage = """
    usage: swift scripts/make-icon.swift <out>.iconset
           swift scripts/make-icon.swift --dmg-background <dir>
    """
let arguments = Array(CommandLine.arguments.dropFirst())
do {
    switch arguments.count {
    case 1 where arguments[0].hasSuffix(".iconset"):
        try makeIconset(at: URL(fileURLWithPath: arguments[0], isDirectory: true))
    case 2 where arguments[0] == "--dmg-background":
        try makeBackground(in: URL(fileURLWithPath: arguments[1], isDirectory: true))
    default:
        fail(usage, status: 64)
    }
} catch {
    fail(error.localizedDescription)
}
