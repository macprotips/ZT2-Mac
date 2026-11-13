// Draws the app icon at every iconset size. Geometry is in a 1024-unit, y-up space.
import AppKit

guard CommandLine.arguments.count > 1 else { print("usage: swift make-icon.swift <output.iconset>"); exit(1) }

let out = CommandLine.arguments[1]
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)

let rgb = CGColorSpaceCreateDeviceRGB()
func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor { CGColor(red: r, green: g, blue: b, alpha: a) }
func gradient(_ a: CGColor, _ b: CGColor) -> CGGradient { CGGradient(colorsSpace: rgb, colors: [a, b] as CFArray, locations: [0, 1])! }

// 824-unit superellipse tile, close to Apple's icon shape.
func tilePath() -> CGPath {
    let p = CGMutablePath(), c: CGFloat = 512, h: CGFloat = 412, n: CGFloat = 7
    for i in 0..<720 {
        let t = CGFloat(i) / 720 * 2 * .pi, ct = cos(t), st = sin(t)
        let x = c + h * (ct < 0 ? -1 : 1) * pow(abs(ct), 2 / n)
        let y = c + h * (st < 0 ? -1 : 1) * pow(abs(st), 2 / n)
        i == 0 ? p.move(to: CGPoint(x: x, y: y)) : p.addLine(to: CGPoint(x: x, y: y))
    }
    p.closeSubpath()
    return p
}

// Main pad, centred on the origin, mirrored about x = 0.
func padPath() -> CGPath {
    let half: [(CGPoint, CGPoint, CGPoint)] = [ // (cp1, cp2, end) for the right half, top -> bottom centre
        (CGPoint(x: 60, y: 112), CGPoint(x: 100, y: 90), CGPoint(x: 125, y: 50)),
        (CGPoint(x: 150, y: 10), CGPoint(x: 165, y: -35), CGPoint(x: 160, y: -72)),
        (CGPoint(x: 155, y: -110), CGPoint(x: 118, y: -118), CGPoint(x: 85, y: -114)),
        (CGPoint(x: 55, y: -110), CGPoint(x: 30, y: -105), CGPoint(x: 0, y: -105)),
    ]
    let p = CGMutablePath()
    p.move(to: CGPoint(x: 0, y: 112))
    for (a, b, e) in half { p.addCurve(to: e, control1: a, control2: b) }
    // Left half: mirror of the right, walked bottom -> top.
    let pts = [CGPoint(x: 0, y: 112)] + half.map { $0.2 }
    for i in stride(from: half.count - 1, through: 0, by: -1) {
        let (a, b, _) = half[i], e = pts[i]
        p.addCurve(to: CGPoint(x: -e.x, y: e.y), control1: CGPoint(x: -b.x, y: b.y), control2: CGPoint(x: -a.x, y: a.y))
    }
    p.closeSubpath()
    return p
}

// Toe pad: an egg, narrow end down, centred on the origin.
func toePath(_ w: CGFloat, _ h: CGFloat) -> CGPath {
    let p = CGMutablePath(), x = w / 2, y = h / 2
    p.move(to: CGPoint(x: 0, y: y))
    p.addCurve(to: CGPoint(x: x, y: h * 0.06), control1: CGPoint(x: x * 0.56, y: y), control2: CGPoint(x: x, y: h * 0.30))
    p.addCurve(to: CGPoint(x: 0, y: -y), control1: CGPoint(x: x, y: -h * 0.24), control2: CGPoint(x: x * 0.52, y: -y))
    p.addCurve(to: CGPoint(x: -x, y: h * 0.06), control1: CGPoint(x: -x * 0.52, y: -y), control2: CGPoint(x: -x, y: -h * 0.24))
    p.addCurve(to: CGPoint(x: 0, y: y), control1: CGPoint(x: -x, y: h * 0.30), control2: CGPoint(x: -x * 0.56, y: y))
    return p
}

// `k` shrinks each pad about its centre so the gaps stay open at small sizes.
func pawPath(_ k: CGFloat) -> CGPath {
    let paw = CGMutablePath(), lift: CGFloat = 22, g: CGFloat = 1.03 // optical nudge upwards; overall size
    func add(_ shape: CGPath, _ x: CGFloat, _ y: CGFloat, _ deg: CGFloat) {
        paw.addPath(shape, transform: CGAffineTransform(translationX: 512 + x * g, y: 512 + (y - 512) * g + lift)
            .rotated(by: deg * .pi / 180).scaledBy(x: k * g, y: k * g))
    }
    add(padPath(), 0, 400, 0)
    for side: CGFloat in [-1, 1] {
        add(toePath(116, 148), side * 80, 636, -side * 9)   // inner toes: higher, larger
        add(toePath(104, 134), side * 204, 556, -side * 30) // outer toes: lower, fanned out
    }
    return paw
}

func draw(_ px: Int) -> Data {
    let s = CGFloat(px), u = s / 1024
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!.cgContext
    ctx.scaleBy(x: u, y: u)
    let tile = tilePath()

    // Tile and drop shadow (shadow metrics are in device pixels).
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10 * u), blur: 20 * u, color: color(0, 0, 0, 0.3))
    ctx.addPath(tile); ctx.setFillColor(color(0.17, 0.40, 0.24)); ctx.fillPath()
    ctx.restoreGState()

    // Savanna-green gradient, lighter at the top.
    ctx.saveGState()
    ctx.addPath(tile); ctx.clip()
    ctx.drawLinearGradient(gradient(color(0.30, 0.55, 0.33), color(0.12, 0.32, 0.19)),
                           start: CGPoint(x: 0, y: 924), end: CGPoint(x: 0, y: 100), options: [])
    // Top-edge highlight.
    ctx.addPath(tile); ctx.setLineWidth(max(4, 2 / u)); ctx.replacePathWithStrokedPath(); ctx.clip()
    ctx.drawLinearGradient(gradient(color(1, 1, 1, 0.22), color(1, 1, 1, 0)),
                           start: CGPoint(x: 0, y: 924), end: CGPoint(x: 0, y: 560), options: [])
    ctx.restoreGState()

    // Paw: cream fill, light gradient, soft shadow.
    let paw = pawPath(px <= 16 ? 0.84 : px <= 32 ? 0.9 : px <= 64 ? 0.95 : 1)
    ctx.saveGState()
    ctx.addPath(tile); ctx.clip()
    ctx.setShadow(offset: CGSize(width: 0, height: -8 * u), blur: 18 * u, color: color(0.02, 0.12, 0.05, 0.35))
    ctx.addPath(paw); ctx.setFillColor(color(0.95, 0.91, 0.81)); ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(paw); ctx.clip()
    ctx.drawLinearGradient(gradient(color(0.99, 0.97, 0.90), color(0.93, 0.88, 0.76)),
                           start: CGPoint(x: 0, y: 760), end: CGPoint(x: 0, y: 290),
                           options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    ctx.restoreGState()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    try! draw(base).write(to: URL(fileURLWithPath: "\(out)/icon_\(base)x\(base).png"))
    try! draw(base * 2).write(to: URL(fileURLWithPath: "\(out)/icon_\(base)x\(base)@2x.png"))
}
