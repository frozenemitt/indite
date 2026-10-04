import AppKit
import CoreImage

// The N, flat: two marks as the uprights, a chisel between them on the diagonal
// through the marks' endpoints, with clear stone at each end. No shadow, no grit.

let azure = NSColor(red: 0.24, green: 0.60, blue: 1.00, alpha: 1)
let violet = NSColor(red: 0.62, green: 0.38, blue: 1.00, alpha: 1)
let size: CGFloat = 512
var tileTop: CGFloat = 0.20
var tileBottom: CGFloat = 0.10

struct Seeded: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 { state = state &* 6364136223846793005 &+ 1442695040888963407; return state }
}

func tile(_ size: CGFloat, draw: (NSRect) -> Void) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    let rect = NSRect(x: 0, y: 0, width: size, height: size)
    NSGraphicsContext.saveGraphicsState()
    NSBezierPath(roundedRect: rect.insetBy(dx: size * 0.04, dy: size * 0.04), xRadius: size * 0.2, yRadius: size * 0.2).addClip()
    NSGradient(starting: NSColor(white: tileTop, alpha: 1), ending: NSColor(white: tileBottom, alpha: 1))!.draw(in: rect, angle: -90)
    draw(rect)
    NSGraphicsContext.restoreGraphicsState()
    image.unlockFocus()
    return image
}


func blurred(_ draw: () -> Void, size: CGSize, radius: CGFloat) -> NSImage? {
    let layer = NSImage(size: size)
    layer.lockFocus()
    draw()
    layer.unlockFocus()
    guard let tiff = layer.tiffRepresentation, let input = CIImage(data: tiff),
          let filter = CIFilter(name: "CIGaussianBlur") else { return nil }
    filter.setValue(input, forKey: kCIInputImageKey)
    filter.setValue(radius, forKey: kCIInputRadiusKey)
    guard let output = filter.outputImage else { return nil }
    let image = NSImage(size: size)
    image.addRepresentation(NSCIImageRep(ciImage: output.cropped(to: input.extent)))
    return image
}

/// How a stick of frosted glass is drawn: a soft shadow under it, a body of white
/// that is brighter toward the light, a rim of light along its upper edges, and,
/// if asked, a sheen. Overlaps brighten on their own, since every layer is
/// see-through.
struct Glass {
    var alpha: CGFloat
    var shadow: CGFloat = 0.30
    var shadowRadius: CGFloat = 9
    var shadowOffset: CGFloat = 7
    var rim: CGFloat = 0.45
    var sheen: CGFloat = 0
}

func glass(_ shape: NSBezierPath, _ g: Glass, in rect: NSRect) {
    let whole = NSRect(origin: .zero, size: rect.size)
    if g.shadow > 0, let shadow = blurred({
        NSColor.black.setFill()
        var shift = CGAffineTransform(translationX: g.shadowOffset * 0.3, y: -g.shadowOffset)
        NSBezierPath(cgPath: shape.cgPath.copy(using: &shift)!).fill()
    }, size: rect.size, radius: g.shadowRadius) {
        shadow.draw(in: whole, from: whole, operation: .sourceOver, fraction: g.shadow)
    }
    // The body: white, a little brighter at the top than the bottom.
    NSGradient(starting: NSColor(white: 1, alpha: min(1, g.alpha + 0.07)), ending: NSColor(white: 1, alpha: max(0, g.alpha - 0.07)))!.draw(in: shape, angle: -90)
    // The rim: the band of the shape not covered by itself shifted down and right.
    if g.rim > 0, let rim = blurred({
        let band = NSBezierPath(rect: rect.insetBy(dx: -40, dy: -40))
        var shift = CGAffineTransform(translationX: 2.5, y: -3.5)
        band.append(NSBezierPath(cgPath: shape.cgPath.copy(using: &shift)!))
        band.windingRule = .evenOdd
        NSColor.white.setFill(); band.fill()
    }, size: rect.size, radius: 1.2) {
        NSGraphicsContext.saveGraphicsState()
        shape.addClip()
        rim.draw(in: whole, from: whole, operation: .sourceOver, fraction: g.rim)
        NSGraphicsContext.restoreGraphicsState()
    }
    if g.sheen > 0, let sheen = blurred({
        let b = shape.bounds
        NSColor.white.setFill()
        NSBezierPath(ovalIn: NSRect(x: b.minX + b.width * 0.15, y: b.minY + b.height * 0.55, width: b.width * 0.7, height: b.height * 0.35)).fill()
    }, size: rect.size, radius: 18) {
        NSGraphicsContext.saveGraphicsState()
        shape.addClip()
        sheen.draw(in: whole, from: whole, operation: .sourceOver, fraction: g.sheen)
        NSGraphicsContext.restoreGraphicsState()
    }
}


/// Every corner of a path softened by about `radius`: the path is flattened to
/// points, and each corner is replaced by a short curve that turns through it.
func softened(_ path: NSBezierPath, radius: CGFloat) -> NSBezierPath {
    let flat = path.flattened
    var points: [CGPoint] = []
    for i in 0..<flat.elementCount {
        var p = [NSPoint](repeating: .zero, count: 3)
        let kind = flat.element(at: i, associatedPoints: &p)
        if kind == .moveTo || kind == .lineTo { points.append(p[0]) }
    }
    if let first = points.first, let last = points.last, hypot(first.x - last.x, first.y - last.y) < 0.5 { points.removeLast() }
    let n = points.count
    let out = NSBezierPath()
    for i in 0..<n {
        let a = points[(i + n - 1) % n], v = points[i], b = points[(i + 1) % n]
        let la = hypot(a.x - v.x, a.y - v.y), lb = hypot(b.x - v.x, b.y - v.y)
        let ta = min(0.5, radius / max(la, 0.001)), tb = min(0.5, radius / max(lb, 0.001))
        let p1 = CGPoint(x: v.x + (a.x - v.x) * ta, y: v.y + (a.y - v.y) * ta)
        let p2 = CGPoint(x: v.x + (b.x - v.x) * tb, y: v.y + (b.y - v.y) * tb)
        if i == 0 { out.move(to: p1) } else { out.line(to: p1) }
        let c1 = CGPoint(x: p1.x + 2 / 3 * (v.x - p1.x), y: p1.y + 2 / 3 * (v.y - p1.y))
        let c2 = CGPoint(x: p2.x + 2 / 3 * (v.x - p2.x), y: p2.y + 2 / 3 * (v.y - p2.y))
        out.curve(to: p2, controlPoint1: c1, controlPoint2: c2)
    }
    out.close()
    return out
}

/// A path as SVG path data, in a `height`-tall box with y running down.
func svgData(_ path: NSBezierPath, height: CGFloat) -> String {
    var d = ""
    for i in 0..<path.elementCount {
        var p = [NSPoint](repeating: .zero, count: 3)
        let kind = path.element(at: i, associatedPoints: &p)
        func f(_ q: NSPoint) -> String { String(format: "%.2f %.2f", q.x, height - q.y) }
        switch kind {
        case .moveTo: d += "M \(f(p[0])) "
        case .lineTo: d += "L \(f(p[0])) "
        case .curveTo, .cubicCurveTo: d += "C \(f(p[0])) \(f(p[1])) \(f(p[2])) "
        case .quadraticCurveTo: d += "Q \(f(p[0])) \(f(p[1])) "
        case .closePath: d += "Z "
        @unknown default: break
        }
    }
    return d
}

/// A polygon with its edges gently broken, as a cut edge is.
func rough(_ corners: [CGPoint], step: CGFloat, amplitude: CGFloat, seed: UInt64) -> NSBezierPath {
    var random = Seeded(state: seed)
    var points: [CGPoint] = []
    for i in 0..<corners.count {
        let a = corners[i], b = corners[(i + 1) % corners.count]
        let length = hypot(b.x - a.x, b.y - a.y)
        let n = max(2, Int(length / step))
        let nx = -(b.y - a.y) / length, ny = (b.x - a.x) / length
        for k in 0..<n {
            let t = CGFloat(k) / CGFloat(n)
            let offset = CGFloat.random(in: -amplitude...amplitude, using: &random)
            points.append(CGPoint(x: a.x + (b.x - a.x) * t + nx * offset, y: a.y + (b.y - a.y) * t + ny * offset))
        }
    }
    let path = NSBezierPath()
    path.move(to: points[0])
    for p in points.dropFirst() { path.line(to: p) }
    path.close()
    return path
}

/// A straight mark from `foot` to `top`, its edges slightly uneven.
func straightMark(foot: CGPoint, top: CGPoint, width: CGFloat, seed: UInt64) -> NSBezierPath {
    let dx = top.x - foot.x, dy = top.y - foot.y
    let l = hypot(dx, dy)
    let nx = -dy / l * width / 2, ny = dx / l * width / 2
    return rough([CGPoint(x: foot.x + nx, y: foot.y + ny), CGPoint(x: top.x + nx, y: top.y + ny),
                  CGPoint(x: top.x - nx, y: top.y - ny), CGPoint(x: foot.x - nx, y: foot.y - ny)],
                 step: 10, amplitude: 1.6, seed: seed)
}

/// The dictation panel's ribbon: the heights the menu bar icon uses.
let profile: [Double] = [
    0.30, 0.50, 0.75, 0.95, 0.80, 0.55, 0.40, 0.55, 0.80, 1.00, 0.85, 0.60,
    0.45, 0.60, 0.80, 0.70, 0.50, 0.35, 0.50, 0.65, 0.50, 0.35, 0.25, 0.20
]

func taper(_ index: Int, of count: Int) -> CGFloat {
    let width = Double(count) / 4
    let distance = Double(min(index, count - 1 - index))
    guard distance < width else { return 1 }
    return CGFloat(0.5 - 0.5 * cos(.pi * distance / width))
}

/// The ribbon as the panel draws it: one closed curve through every band, mirrored
/// about its centre line, pinched to a point at both ends. Laid along `from` to
/// `to`, `reach` thick at a full swell.
func ribbonMark(from a: CGPoint, to b: CGPoint, reach: CGFloat, amplitudes: [Double]) -> NSBezierPath {
    let dx = b.x - a.x, dy = b.y - a.y
    let length = hypot(dx, dy)
    let ux = dx / length, uy = dy / length
    let nx = -uy, ny = ux
    let resting: CGFloat = 1.5
    let step = length / CGFloat(amplitudes.count - 1)
    var top: [CGPoint] = [], bottom: [CGPoint] = []
    for (i, value) in amplitudes.enumerated() {
        let thickness = (resting + (reach - resting) * CGFloat(value)) * taper(i, of: amplitudes.count)
        let p = CGPoint(x: a.x + ux * step * CGFloat(i), y: a.y + uy * step * CGFloat(i))
        top.append(CGPoint(x: p.x + nx * thickness, y: p.y + ny * thickness))
        bottom.append(CGPoint(x: p.x - nx * thickness, y: p.y - ny * thickness))
    }
    let path = NSBezierPath()
    func append(_ points: [CGPoint], starting: Bool) {
        guard let first = points.first, let last = points.last else { return }
        if starting { path.move(to: first) } else { path.line(to: first) }
        var from = first
        for i in 0..<(points.count - 1) {
            let control = points[i], next = points[i + 1]
            let to = CGPoint(x: (control.x + next.x) / 2, y: (control.y + next.y) / 2)
            let c1 = CGPoint(x: from.x + 2 / 3 * (control.x - from.x), y: from.y + 2 / 3 * (control.y - from.y))
            let c2 = CGPoint(x: to.x + 2 / 3 * (control.x - to.x), y: to.y + 2 / 3 * (control.y - to.y))
            path.curve(to: to, controlPoint1: c1, controlPoint2: c2)
            from = to
        }
        path.line(to: last)
    }
    append(top, starting: true)
    append(bottom.reversed(), starting: false)
    path.close()
    return path
}

/// The chisel, its features in silhouette: a flat head at the struck end a little
/// wider than the shank, the shank, a blade that flares to a broad straight edge.
func chiselPath(from butt: CGPoint, to edge: CGPoint, width w: CGFloat, headWidth: CGFloat = 1.12) -> NSBezierPath {
    let dx = edge.x - butt.x, dy = edge.y - butt.y
    let length = hypot(dx, dy)
    let angle = atan2(dy, dx) * 180 / .pi
    let headLength = w * 0.95, headHalf = w * 0.5 * headWidth
    let shankHalf = w * 0.5
    let bladeLength = length * 0.26, edgeHalf = w * 0.80
    let body = NSBezierPath()
    body.move(to: CGPoint(x: 0, y: -headHalf + w * 0.12))
    body.curve(to: CGPoint(x: w * 0.12, y: -headHalf), controlPoint1: CGPoint(x: 0, y: -headHalf + w * 0.05), controlPoint2: CGPoint(x: w * 0.05, y: -headHalf))
    body.line(to: CGPoint(x: headLength, y: -headHalf))
    body.line(to: CGPoint(x: headLength + w * 0.2, y: -shankHalf))
    body.line(to: CGPoint(x: length - bladeLength, y: -shankHalf))
    body.line(to: CGPoint(x: length, y: -edgeHalf))
    body.line(to: CGPoint(x: length, y: edgeHalf))
    body.line(to: CGPoint(x: length - bladeLength, y: shankHalf))
    body.line(to: CGPoint(x: headLength + w * 0.2, y: shankHalf))
    body.line(to: CGPoint(x: headLength, y: headHalf))
    body.line(to: CGPoint(x: w * 0.12, y: headHalf))
    body.curve(to: CGPoint(x: 0, y: headHalf - w * 0.12), controlPoint1: CGPoint(x: w * 0.05, y: headHalf), controlPoint2: CGPoint(x: 0, y: headHalf - w * 0.05))
    body.close()
    let transform = NSAffineTransform()
    transform.translateX(by: butt.x, yBy: butt.y)
    transform.rotate(byDegrees: angle)
    return transform.transform(body)
}

/// A mark between a clean stroke and the ribbon: a stroke that swells by `swell`
/// of its width where the voice would, its ends tapered to `endWidth` of it, its
/// long edges broken a little. The ends are rounded, or cut flat at `cutAngle`
/// degrees to the stroke, the way a chisel leaves a terminal.
func breathingMark(from a: CGPoint, to b: CGPoint, width: CGFloat, swell: CGFloat, heights: [Double], roughness: CGFloat, seed: UInt64, endWidth: CGFloat = 1.0, cutAngle: CGFloat? = nil) -> NSBezierPath {
    let dx = b.x - a.x, dy = b.y - a.y
    let length = hypot(dx, dy)
    let ux = dx / length, uy = dy / length
    let nx = -uy, ny = ux
    let half = width / 2
    var random = Seeded(state: seed)
    let samples = 44
    func height(at t: CGFloat) -> CGFloat {
        let position = t * CGFloat(heights.count - 1)
        let i = min(heights.count - 2, Int(position))
        let f = position - CGFloat(i)
        let eased = (1 - cos(f * .pi)) / 2
        return CGFloat(heights[i]) * (1 - eased) + CGFloat(heights[i + 1]) * eased
    }
    func taper(_ t: CGFloat) -> CGFloat {
        let d = min(t, 1 - t) / 0.28
        guard d < 1 else { return 1 }
        let eased = (1 - cos(d * .pi)) / 2
        return endWidth + (1 - endWidth) * eased
    }
    var top: [CGPoint] = [], bottom: [CGPoint] = []
    for k in 0...samples {
        let t = CGFloat(k) / CGFloat(samples)
        let thickness = half * (1 - swell + swell * height(at: t)) * taper(t)
        let p = CGPoint(x: a.x + ux * length * t, y: a.y + uy * length * t)
        // The roughness fades out over the last tenth at each end, so the points stay clean.
        let fade = min(1, min(t, 1 - t) / 0.1)
        let j1 = CGFloat.random(in: -roughness...roughness, using: &random) * fade
        let j2 = CGFloat.random(in: -roughness...roughness, using: &random) * fade
        top.append(CGPoint(x: p.x + nx * (thickness + j1), y: p.y + ny * (thickness + j1)))
        bottom.append(CGPoint(x: p.x - nx * (thickness + j2), y: p.y - ny * (thickness + j2)))
    }
    let angle = atan2(uy, ux) * 180 / .pi
    let path = NSBezierPath()
    if let cutAngle {
        // A flat terminal at an angle: one edge runs on past the other.
        let endT = half * endWidth * tan(cutAngle * .pi / 180)
        let topEnd = CGPoint(x: top[samples].x + ux * endT, y: top[samples].y + uy * endT)
        let bottomEnd = CGPoint(x: bottom[samples].x - ux * endT, y: bottom[samples].y - uy * endT)
        let topStart = CGPoint(x: top[0].x + ux * endT, y: top[0].y + uy * endT)
        let bottomStart = CGPoint(x: bottom[0].x - ux * endT, y: bottom[0].y - uy * endT)
        path.move(to: topStart)
        for p in top.dropFirst().dropLast() { path.line(to: p) }
        path.line(to: topEnd)
        path.line(to: bottomEnd)
        for p in bottom.dropFirst().dropLast().reversed() { path.line(to: p) }
        path.line(to: bottomStart)
        path.close()
        return path
    }
    path.move(to: top[0])
    for p in top.dropFirst() { path.line(to: p) }
    let endR = hypot(top[samples].x - b.x, top[samples].y - b.y)
    path.appendArc(withCenter: b, radius: endR, startAngle: angle + 90, endAngle: angle - 90, clockwise: true)
    for p in bottom.reversed() { path.line(to: p) }
    let startR = hypot(top[0].x - a.x, top[0].y - a.y)
    path.appendArc(withCenter: a, radius: startR, startAngle: angle - 90, endAngle: angle + 90, clockwise: true)
    path.close()
    return path
}

/// Where the marks stand, and the diagonal through their endpoints.
struct Frame {
    let leftFoot: CGPoint, leftTop: CGPoint, rightFoot: CGPoint, rightTop: CGPoint
    init(_ rect: NSRect) {
        let height = rect.height * 0.54
        let lean: CGFloat = 0.14
        let footY = rect.midY - height * 0.5
        leftFoot = CGPoint(x: rect.midX - rect.width * 0.24, y: footY)
        rightFoot = CGPoint(x: rect.midX + rect.width * 0.17, y: footY)
        leftTop = CGPoint(x: leftFoot.x + lean * height, y: footY + height)
        rightTop = CGPoint(x: rightFoot.x + lean * height, y: footY + height)
    }
}

let white = NSColor.white
let swellsA: [Double] = [0.55, 1.00, 0.70, 0.95, 0.45, 0.85, 0.60, 0.90, 0.50]
let swellsThree: [Double] = [0.45, 0.80, 0.55, 1.00, 0.60, 0.85, 0.45]

struct Design {
    var markAlpha: CGFloat = 0.62
    var chiselAlpha: CGFloat = 0.62
    var swell: CGFloat = 0.40
    var heights: [Double] = swellsA
    var roughness: CGFloat = 1.6
    var reach: CGFloat = size * 0.10
    var markWidth: CGFloat = size * 0.11
    var chiselWidth: CGFloat = size * 0.135
    var headWidth: CGFloat = 1.12
    var endWidth: CGFloat = 0.55
    var cutAngle: CGFloat? = nil
    var scale: CGFloat = 1.0
    var corner: CGFloat = 0
}

struct Finish {
    var marks: Glass
    var chisel: Glass
}

func compose(_ d: Design, finish: Finish) -> NSImage {
    tile(size) { rect in
        let f = Frame(rect)
        let left = breathingMark(from: f.leftFoot, to: f.leftTop, width: d.markWidth, swell: d.swell, heights: d.heights, roughness: d.roughness, seed: 11, endWidth: d.endWidth, cutAngle: d.cutAngle)
        let right = breathingMark(from: f.rightFoot, to: f.rightTop, width: d.markWidth, swell: d.swell, heights: d.heights.reversed(), roughness: d.roughness, seed: 23, endWidth: d.endWidth, cutAngle: d.cutAngle)
        let dx = f.rightFoot.x - f.leftTop.x, dy = f.rightFoot.y - f.leftTop.y
        let l = hypot(dx, dy)
        let butt = CGPoint(x: f.leftTop.x - dx / l * d.reach, y: f.leftTop.y - dy / l * d.reach)
        let edge = CGPoint(x: f.rightFoot.x + dx / l * d.reach, y: f.rightFoot.y + dy / l * d.reach)
        let tool = chiselPath(from: butt, to: edge, width: d.chiselWidth, headWidth: d.headWidth)
        let all = NSBezierPath(); all.append(left); all.append(right); all.append(tool)
        let bounds = all.bounds
        let move = NSAffineTransform()
        move.translateX(by: rect.midX, yBy: rect.midY)
        move.scale(by: d.scale)
        move.translateX(by: -bounds.midX, yBy: -bounds.midY)
        let shapes = [move.transform(left), move.transform(right), move.transform(tool)].map { softened($0, radius: d.corner) }
        glass(shapes[0], finish.marks, in: rect)
        glass(shapes[1], finish.marks, in: rect)
        glass(shapes[2], finish.chisel, in: rect)
        lastShapes = shapes
    }
}
var lastShapes: [NSBezierPath] = []

var base = Design(); base.headWidth = 1.0; base.endWidth = 0.3; base.cutAngle = 40; base.scale = 0.92
base.heights = swellsThree; base.swell = 0.36
base.chiselWidth = size * 0.12; base.reach = size * 0.10
base.roughness = 1.2

base.roughness = 0.7
var soft = base; soft.corner = 6
var softer = base; softer.corner = 10
let finish = Finish(marks: Glass(alpha: 0.80, shadow: 0.38, shadowRadius: 10, shadowOffset: 8), chisel: Glass(alpha: 0.56, shadow: 0.38, shadowRadius: 10, shadowOffset: 8))

let sheet = NSImage(size: NSSize(width: 1800, height: 700))
sheet.lockFocus()
NSColor(white: 0.97, alpha: 1).setFill()
NSRect(x: 0, y: 0, width: 1800, height: 700).fill()
let labels = ["Q0  As before", "Q1  Corners softened by 6", "Q2  Corners softened by 10"]
for (index, design) in [base, soft, softer].enumerated() {
    let icon = compose(design, finish: finish)
    let x = CGFloat(index) * 600 + 44
    icon.draw(in: NSRect(x: x, y: 150, width: 512, height: 512))
    icon.draw(in: NSRect(x: x + 380, y: 40, width: 96, height: 96))
    icon.draw(in: NSRect(x: x + 490, y: 60, width: 48, height: 48))
    NSAttributedString(string: labels[index], attributes: [.font: NSFont.systemFont(ofSize: 26, weight: .semibold), .foregroundColor: NSColor.black]).draw(at: NSPoint(x: x, y: 70))
}
sheet.unlockFocus()
let rep = NSBitmapImageRep(data: sheet.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "soft.png"))

// The layers for Icon Composer, drawn at 1024 from the softened shapes: the marks
// as one SVG, the chisel as another, white on nothing.
_ = compose(soft, finish: finish)
let k: CGFloat = 1024 / size
let scaled = lastShapes.map { shape -> NSBezierPath in
    let t = NSAffineTransform(); t.scale(by: k); return t.transform(shape)
}
func svg(_ paths: [NSBezierPath], name: String) {
    var body = "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"1024\" height=\"1024\" viewBox=\"0 0 1024 1024\">\n"
    for p in paths { body += "  <path d=\"\(svgData(p, height: 1024))\" fill=\"#FFFFFF\"/>\n" }
    body += "</svg>\n"
    try! body.write(toFile: name, atomically: true, encoding: .utf8)
}
svg([scaled[0], scaled[1]], name: "layer-marks.svg")
svg([scaled[2]], name: "layer-chisel.svg")
func png(_ paths: [NSBezierPath], name: String) {
    let image = NSImage(size: NSSize(width: 1024, height: 1024))
    image.lockFocus()
    NSColor.white.setFill()
    for p in paths { p.fill() }
    image.unlockFocus()
    let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: name))
}
png([scaled[0], scaled[1]], name: "layer-marks.png")
png([scaled[2]], name: "layer-chisel.png")
print("drawn")
