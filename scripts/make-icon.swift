// Draws Glim's artwork with CoreGraphics, so no image is checked in and no
// design tool is needed.
//
//   swift scripts/make-icon.swift <out>.iconset            the app icon, every size macOS uses
//   swift scripts/make-icon.swift --dmg-background <dir>   the DMG window background, 1x and 2x
//
// The icon follows the macOS (Big Sur and later) app icon grid: a 1024 px
// canvas holding an 824 px rounded square with continuous corners, a 100 px
// margin, and a soft drop shadow that falls into the margin. Every size is
// drawn from the same shapes rather than downscaled; 16 and 32 pt get bolder
// sun rays so that the motif survives at menu-list size.

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

// MARK: - Geometry

/// A rounded rectangle with continuous corners, built the way Figma's corner
/// smoothing builds them: each corner eases from the straight edge into a
/// shorter circular arc instead of meeting a quarter circle head-on. A
/// smoothing of 0.6 matches the shape of Apple's app icons.
func continuousRect(_ rect: CGRect, radius: CGFloat, smoothing s: CGFloat = 0.6) -> CGPath {
    let r = min(radius, min(rect.width, rect.height) / 2 / (1 + s))
    let p = (1 + s) * r
    let degrees = CGFloat.pi / 180
    let arcAngle = 90 * (1 - s) * degrees
    let arc = sin(arcAngle / 2) * r * 2.squareRoot()
    let c = r * tan(45 * s * degrees / 2) * cos(45 * s * degrees)
    let d = c * tan(45 * s * degrees)
    let b = (p - arc - c - d) / 3
    let a = 2 * b
    let handle = 4 / 3 * tan(arcAngle / 4) * r

    // Each corner is described from its vertex k, with u the direction of the
    // edge arriving at it and v the direction of the edge leaving it.
    func at(_ k: CGPoint, _ u: CGVector, _ i: CGFloat, _ v: CGVector, _ j: CGFloat) -> CGPoint {
        CGPoint(x: k.x + u.dx * i + v.dx * j, y: k.y + u.dy * i + v.dy * j)
    }
    func unit(_ u: CGVector, _ i: CGFloat, _ v: CGVector, _ j: CGFloat) -> CGVector {
        let x = u.dx * i + v.dx * j, y = u.dy * i + v.dy * j
        let n = (x * x + y * y).squareRoot()
        return n == 0 ? u : CGVector(dx: x / n, dy: y / n)
    }

    let corners: [(CGPoint, CGVector, CGVector)] = [
        (CGPoint(x: rect.maxX, y: rect.minY), CGVector(dx: 1, dy: 0), CGVector(dx: 0, dy: 1)),
        (CGPoint(x: rect.maxX, y: rect.maxY), CGVector(dx: 0, dy: 1), CGVector(dx: -1, dy: 0)),
        (CGPoint(x: rect.minX, y: rect.maxY), CGVector(dx: -1, dy: 0), CGVector(dx: 0, dy: -1)),
        (CGPoint(x: rect.minX, y: rect.minY), CGVector(dx: 0, dy: -1), CGVector(dx: 1, dy: 0)),
    ]
    let path = CGMutablePath()
    for (index, (k, u, v)) in corners.enumerated() {
        let start = at(k, u, -p, v, 0)
        if index == 0 { path.move(to: start) } else { path.addLine(to: start) }
        let arcStart = at(k, u, -(p - a - b - c), v, d)
        let arcEnd = at(k, u, -d, v, d + arc)
        path.addCurve(to: arcStart, control1: at(k, u, -(p - a), v, 0), control2: at(k, u, -(p - a - b), v, 0))
        let t1 = unit(u, c, v, d), t2 = unit(u, d, v, c)
        path.addCurve(
            to: arcEnd,
            control1: CGPoint(x: arcStart.x + t1.dx * handle, y: arcStart.y + t1.dy * handle),
            control2: CGPoint(x: arcEnd.x - t2.dx * handle, y: arcEnd.y - t2.dy * handle)
        )
        path.addCurve(to: at(k, u, 0, v, p), control1: at(k, u, 0, v, d + arc + c), control2: at(k, u, 0, v, d + arc + b + c))
    }
    path.closeSubpath()
    return path
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

// Design units: the 1024-unit canvas of Apple's macOS icon template.
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let tileRadius: CGFloat = 185.4

/// The whole icon: a night-blue tile holding a silver display whose screen
/// glows around a sun, the brightness glyph.
func drawIcon(_ canvas: Canvas, small: Bool) {
    let ctx = canvas.context
    let tilePath = continuousRect(tile, radius: tileRadius)

    // Tile, with the template's drop shadow in the margin.
    ctx.saveGState()
    canvas.shadow(y: 10, blur: 22, color(0x000000, 0.32))
    canvas.fill(tilePath, color(0x1B2246))
    ctx.restoreGState()
    canvas.fill(tilePath, gradient([(0, color(0x41508F)), (1, color(0x141936))]), from: CGPoint(x: 0, y: 100), to: CGPoint(x: 0, y: 924))

    ctx.saveGState()
    ctx.addPath(tilePath)
    ctx.clip()
    // Light from the screen spilling onto the tile.
    ctx.drawRadialGradient(
        gradient([(0, color(0xA48CFF, 0.24)), (1, color(0xA48CFF, 0))]),
        startCenter: CGPoint(x: 512, y: 440), startRadius: 0,
        endCenter: CGPoint(x: 512, y: 440), endRadius: 440, options: []
    )
    // A rim of light along the top edge that fades out by mid-height.
    ctx.addPath(tilePath)
    ctx.setLineWidth(6)
    ctx.replacePathWithStrokedPath()
    ctx.clip()
    ctx.drawLinearGradient(
        gradient([(0, color(0xFFFFFF, 0.30)), (1, color(0xFFFFFF, 0))]),
        start: CGPoint(x: 0, y: 100), end: CGPoint(x: 0, y: 560), options: []
    )
    ctx.restoreGState()

    // Stand: neck, then foot, both brushed aluminium.
    let neck = CGRect(x: 470, y: 620, width: 84, height: 132)
    canvas.fill(CGPath(rect: neck, transform: nil), gradient([
        (0, color(0x9EA5B6)), (0.22, color(0xD8DCE5)), (0.78, color(0xD8DCE5)), (1, color(0x9EA5B6)),
    ]), from: CGPoint(x: neck.minX, y: 0), to: CGPoint(x: neck.maxX, y: 0))
    let footRect = CGRect(x: 360, y: 744, width: 304, height: 34)
    let foot = continuousRect(footRect, radius: 17)
    ctx.saveGState()
    canvas.shadow(y: 8, blur: 18, color(0x000000, 0.45))
    canvas.fill(foot, color(0xC9CED9))
    ctx.restoreGState()
    canvas.fill(foot, gradient([(0, color(0xF4F6FA)), (1, color(0xAEB4C3))]), from: CGPoint(x: 0, y: footRect.minY), to: CGPoint(x: 0, y: footRect.maxY))

    // Display body: aluminium shell, black glass bezel, then the screen.
    let bodyRect = CGRect(x: 182, y: 226, width: 660, height: 412)
    let body = continuousRect(bodyRect, radius: 46)
    ctx.saveGState()
    canvas.shadow(y: 18, blur: 40, color(0x000000, 0.50))
    canvas.fill(body, color(0xD5DAE4))
    ctx.restoreGState()
    canvas.fill(body, gradient([(0, color(0xF7F8FB)), (1, color(0xC3C9D6))]), from: CGPoint(x: 0, y: bodyRect.minY), to: CGPoint(x: 0, y: bodyRect.maxY))
    canvas.fill(continuousRect(bodyRect.insetBy(dx: 14, dy: 14), radius: 34), color(0x0A0C16))
    let screenRect = bodyRect.insetBy(dx: 28, dy: 28)
    let screen = continuousRect(screenRect, radius: 22)

    // Screen: dim indigo at the edges warming to a bright centre.
    let sun = CGPoint(x: screenRect.midX, y: screenRect.midY)
    ctx.saveGState()
    ctx.addPath(screen)
    ctx.clip()
    canvas.fill(screen, gradient([(0, color(0x2B3A86)), (1, color(0x4B3577))]), from: CGPoint(x: 0, y: screenRect.minY), to: CGPoint(x: 0, y: screenRect.maxY))
    ctx.drawRadialGradient(
        gradient([
            (0, color(0xFFF2C2)), (0.22, color(0xFFD27E)), (0.5, color(0xF2875E, 0.85)), (1, color(0xB04F7A, 0)),
        ]),
        startCenter: sun, startRadius: 0, endCenter: sun, endRadius: 360, options: []
    )
    if !small {
        // Glass reflection across the upper left.
        let sheen = CGMutablePath()
        sheen.move(to: CGPoint(x: screenRect.minX, y: screenRect.minY))
        sheen.addLine(to: CGPoint(x: screenRect.minX + 360, y: screenRect.minY))
        sheen.addLine(to: CGPoint(x: screenRect.minX + 150, y: screenRect.maxY))
        sheen.addLine(to: CGPoint(x: screenRect.minX, y: screenRect.maxY))
        sheen.closeSubpath()
        canvas.fill(sheen, gradient([(0, color(0xFFFFFF, 0.10)), (1, color(0xFFFFFF, 0))]), from: CGPoint(x: screenRect.minX, y: screenRect.minY), to: CGPoint(x: screenRect.minX + 260, y: screenRect.maxY))
    }
    ctx.restoreGState()

    // Sun: a disc and eight rounded rays.
    let disc: CGFloat = small ? 74 : 64
    let rays: (inner: CGFloat, outer: CGFloat, width: CGFloat) = small ? (108, 150, 38) : (98, 134, 24)
    ctx.saveGState()
    canvas.shadow(y: 0, blur: 30, color(0xFFE6A0, 0.9))
    ctx.setStrokeColor(color(0xFFF8E6))
    ctx.setLineWidth(rays.width)
    ctx.setLineCap(.round)
    for i in 0..<8 {
        let angle = CGFloat(i) * .pi / 4
        ctx.move(to: CGPoint(x: sun.x + cos(angle) * rays.inner, y: sun.y + sin(angle) * rays.inner))
        ctx.addLine(to: CGPoint(x: sun.x + cos(angle) * rays.outer, y: sun.y + sin(angle) * rays.outer))
    }
    ctx.strokePath()
    let discPath = CGPath(ellipseIn: CGRect(x: sun.x - disc, y: sun.y - disc, width: disc * 2, height: disc * 2), transform: nil)
    canvas.fill(discPath, color(0xFFFCF2))
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(discPath)
    ctx.clip()
    ctx.drawRadialGradient(
        gradient([(0, color(0xFFFFFF)), (0.8, color(0xFFFCF2)), (1, color(0xFFF3D6))]),
        startCenter: CGPoint(x: sun.x - disc * 0.25, y: sun.y - disc * 0.3), startRadius: 0,
        endCenter: sun, endRadius: disc, options: [.drawsAfterEndLocation]
    )
    ctx.restoreGState()
}

// MARK: - DMG background

// Window content in points. Must match the layout in scripts/make-dmg.sh:
// icons are centred at (160, 196) and (480, 196). The image is taller than the
// 400 pt the window shows so that a title bar of any height never uncovers the
// plain window behind it.
let backgroundSize = CGSize(width: 640, height: 432)
let iconCentreY: CGFloat = 196

/// A dusk gradient with an arrow from the app to Applications. The tones stay
/// mid-dark under the icon labels, where Finder draws black text in Light Mode
/// and white text in Dark Mode, so the labels read in both.
func drawBackground(_ canvas: Canvas) {
    let ctx = canvas.context
    let all = CGPath(rect: CGRect(origin: .zero, size: backgroundSize), transform: nil)
    canvas.fill(all, gradient([(0, color(0x4C598F)), (1, color(0x7276A5))]), from: .zero, to: CGPoint(x: 0, y: backgroundSize.height))
    ctx.saveGState()
    ctx.addPath(all)
    ctx.clip()
    ctx.drawRadialGradient(
        gradient([(0, color(0xFFB27A, 0.42)), (1, color(0xFFB27A, 0))]),
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
    for points in [16, 32, 128, 256, 512] {
        for factor in [1, 2] {
            let pixels = points * factor
            let canvas = Canvas(width: pixels, height: pixels, units: 1024)
            drawIcon(canvas, small: points <= 32)
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
