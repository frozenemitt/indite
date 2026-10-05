// The app icon's shapes, and the menu bar's.
//
// Two quotation marks stand as the uprights of an N, and a carver's chisel lies
// across them as its diagonal. This draws the three shapes and writes them as the
// SVG layers of the Icon Composer document, and draws the same N small for the
// menu bar. The tile, the glass, the opacities and the order of the icon's layers
// live in the document's icon.json, which Icon Composer edits; nothing here
// touches them.
//
//     swift Design/Icon/draw-icon.swift
//
// from the repository's root writes marks.svg and chisel.svg into
// Inscribe/AppIcon.icon/Assets, and the two menu bar images into the asset catalog.

import AppKit

/// The drawing's units. The SVGs are written at 1024.
let size: CGFloat = 512

// The design, as settled on 2026-10-04.
let markLean: CGFloat = 12          // degrees off vertical, leaning right
let markTip: CGFloat = 0.45         // the tail's width as a share of the head's
let markBend: CGFloat = 0.10        // how far the axis bends left over the length, in widths
let markWidth = size * 0.15
let markHeight = size * 0.54
let markSpread = size * 0.30        // between the marks' centres
let chiselAngle: CGFloat = 45       // below the horizontal, about the N's middle
let chiselLength = size * 0.75
let chiselWidth = markWidth * 0.6
/// The chisel's outline from butt to edge: (position along the length, half-width in widths).
let chiselProfile: [(CGFloat, CGFloat)] = [(0, 0.4), (0.02, 0.5), (0.74, 0.5), (1, 0.64)]
let chiselSkew: CGFloat = 0.8       // the edge cut on a slant, by this many widths
let drawingScale: CGFloat = 0.84    // the whole drawing, about the tile's centre
let cornerRadius: CGFloat = 2       // a little off every sharp corner

// The menu bar's N, in points.
let menuHeight: CGFloat = 16
let menuGap: CGFloat = 1            // cut between the chisel and the marks it crosses
let menuChiselAlpha: CGFloat = 0.55 // the chisel lighter than the marks, as on the icon
let menuTileGlyph: CGFloat = 0.70   // the N's height in the filled tile, as a share of it
let menuTileRadius: CGFloat = 0.225 // the tile's corner radius, as a share of its side

// MARK: - A mark

/// A quotation mark as one stroke: one unit wide, rounded at the head, narrowing
/// evenly to `tip` of its width at a rounded tail, its axis bending left by `bend`
/// over its `length`, the whole mark leaning `lean` degrees to the right. Drawn at
/// a hundred units to the width.
func strokeMark(length: CGFloat, tip: CGFloat, bend: CGFloat, lean: CGFloat) -> NSBezierPath {
    let r: CGFloat = 0.5, n = 64
    func centre(_ t: CGFloat) -> CGPoint { CGPoint(x: -bend * t * t, y: -length * t) }
    func normal(_ t: CGFloat) -> CGPoint { let dx = -2 * bend * t, dy = -length; let l = hypot(dx, dy); return CGPoint(x: -dy / l, y: dx / l) }
    func half(_ t: CGFloat) -> CGFloat { r * (1 - (1 - tip) * t) }
    var right: [CGPoint] = [], left: [CGPoint] = []
    for k in 0...n {
        let t = CGFloat(k) / CGFloat(n), c = centre(t), m = normal(t), h = half(t)
        right.append(CGPoint(x: c.x + m.x * h, y: c.y + m.y * h))
        left.append(CGPoint(x: c.x - m.x * h, y: c.y - m.y * h))
    }
    let p = NSBezierPath()
    p.move(to: right[0])
    for q in right.dropFirst() { p.line(to: q) }
    let end = centre(1)
    let aR = atan2(right[n].y - end.y, right[n].x - end.x) * 180 / .pi
    let aL = atan2(left[n].y - end.y, left[n].x - end.x) * 180 / .pi
    p.appendArc(withCenter: end, radius: half(1), startAngle: aR, endAngle: aL, clockwise: true)
    for q in left.dropLast().reversed() { p.line(to: q) }
    p.appendArc(withCenter: .zero, radius: r, startAngle: 180, endAngle: 0, clockwise: true)
    p.close()
    let t = NSAffineTransform()
    t.scale(by: 100)
    t.rotate(byDegrees: -lean)
    return t.transform(p)
}

/// A mark `markWidth` wide and `markHeight` tall, centred on `centreX` and the tile's middle.
func mark(centreX: CGFloat, in rect: NSRect) -> NSBezierPath {
    // The length that gives the height: try, measure, scale.
    var length: CGFloat = 2.5
    for _ in 0..<4 {
        let m = strokeMark(length: length, tip: markTip, bend: markBend, lean: markLean)
        length *= markHeight / markWidth / (m.bounds.height / 100)
        length = max(1, length)
    }
    let m = strokeMark(length: length, tip: markTip, bend: markBend, lean: markLean)
    let b = m.bounds
    let t = NSAffineTransform()
    t.translateX(by: centreX, yBy: rect.midY)
    t.scale(by: markWidth / 100)
    t.translateX(by: -b.midX, yBy: -b.midY)
    return t.transform(m)
}

// MARK: - The chisel

/// A chisel from its profile, lying from `butt` to `edge`, `w` wide. The outline
/// runs out along one side and back along the other; a positive `skew` pulls the
/// edge's lower corner back by that many widths, cutting the edge on a slant.
func profiledChisel(from butt: CGPoint, to edge: CGPoint, width w: CGFloat, profile: [(CGFloat, CGFloat)], skew: CGFloat) -> NSBezierPath {
    let dx = edge.x - butt.x, dy = edge.y - butt.y
    let length = hypot(dx, dy), angle = atan2(dy, dx) * 180 / .pi
    let xTop = length - max(0, -skew) * w, xBottom = length - max(0, skew) * w
    func halfAt(_ x: CGFloat) -> CGFloat {
        let t = x / length
        var i = 0
        while i < profile.count - 2 && profile[i + 1].0 < t { i += 1 }
        let (t1, h1) = profile[i], (t2, h2) = profile[i + 1]
        return (h1 + (h2 - h1) * ((t - t1) / max(t2 - t1, 0.0001))) * w
    }
    var top: [CGPoint] = [], bottom: [CGPoint] = []
    for (t, h) in profile.dropLast() {
        top.append(CGPoint(x: t * length, y: h * w)); bottom.append(CGPoint(x: t * length, y: -h * w))
    }
    top.append(CGPoint(x: xTop, y: halfAt(xTop))); bottom.append(CGPoint(x: xBottom, y: -halfAt(xBottom)))
    let body = NSBezierPath()
    body.move(to: top[0]); for p in top.dropFirst() { body.line(to: p) }
    for p in bottom.reversed() { body.line(to: p) }
    body.close()
    let transform = NSAffineTransform()
    transform.translateX(by: butt.x, yBy: butt.y)
    transform.rotate(byDegrees: angle)
    return transform.transform(body)
}

// MARK: - Finishing

/// The path with every corner rounded off by `radius`.
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

/// The shapes scaled together about the tile's centre and softened.
func composed(_ shapes: [NSBezierPath], in rect: NSRect) -> [NSBezierPath] {
    let all = NSBezierPath(); for p in shapes { all.append(p) }
    let bounds = all.bounds
    let move = NSAffineTransform()
    move.translateX(by: rect.midX, yBy: rect.midY)
    move.scale(by: drawingScale)
    move.translateX(by: -bounds.midX, yBy: -bounds.midY)
    return shapes.map { softened(move.transform($0), radius: cornerRadius) }
}

/// A path as SVG path data, in a `height`-tall box with y running down.
func svgData(_ path: CGPath, height: CGFloat, digits: Int) -> String {
    var d = ""
    let format = "%.\(digits)f %.\(digits)f"
    path.applyWithBlock { element in
        let p = element.pointee.points
        func f(_ q: CGPoint) -> String { String(format: format, q.x, height - q.y) }
        switch element.pointee.type {
        case .moveToPoint: d += "M \(f(p[0])) "
        case .addLineToPoint: d += "L \(f(p[0])) "
        case .addQuadCurveToPoint: d += "Q \(f(p[0])) \(f(p[1])) "
        case .addCurveToPoint: d += "C \(f(p[0])) \(f(p[1])) \(f(p[2])) "
        case .closeSubpath: d += "Z "
        @unknown default: break
        }
    }
    return d
}

/// Paths as one SVG `width` by `height`, each filled with `fill` at its own opacity.
func writeSVG(_ layers: [(path: CGPath, alpha: CGFloat)], width: CGFloat, height: CGFloat, fill: String, digits: Int, to file: String) {
    func g(_ v: CGFloat) -> String { String(format: "%g", v) }
    var body = "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"\(g(width))\" height=\"\(g(height))\" viewBox=\"0 0 \(g(width)) \(g(height))\">\n"
    for layer in layers {
        let opacity = layer.alpha < 1 ? " fill-opacity=\"\(g(layer.alpha))\"" : ""
        body += "  <path d=\"\(svgData(layer.path, height: height, digits: digits))\" fill=\"\(fill)\"\(opacity)/>\n"
    }
    body += "</svg>\n"
    try! body.write(toFile: file, atomically: true, encoding: .utf8)
}

/// The paths as one white layer of the icon document, 1024 to a side.
func writeIconLayer(_ paths: [NSBezierPath], to file: String) {
    var k = CGAffineTransform(scaleX: 1024 / size, y: 1024 / size)
    writeSVG(paths.map { (path: $0.cgPath.copy(using: &k)!, alpha: 1) }, width: 1024, height: 1024, fill: "#FFFFFF", digits: 2, to: file)
}

// MARK: - The drawing

let rect = NSRect(x: 0, y: 0, width: size, height: size)
let left = mark(centreX: rect.midX - markSpread / 2, in: rect)
let right = mark(centreX: rect.midX + markSpread / 2, in: rect)

// The chisel pivots about the middle of the line from the left mark's head to the
// right mark's tail, its butt at the top-left and its edge at the bottom-right.
let lb = left.bounds, rb = right.bounds
let top = CGPoint(x: lb.maxX - markWidth / 2, y: lb.maxY - markWidth / 2)
let foot = CGPoint(x: rb.minX + markTip * markWidth / 2, y: rb.minY + markTip * markWidth / 2)
let centre = CGPoint(x: (top.x + foot.x) / 2, y: (top.y + foot.y) / 2)
let half = chiselLength / 2
let dx = cos(chiselAngle * .pi / 180), dy = -sin(chiselAngle * .pi / 180)
let butt = CGPoint(x: centre.x - dx * half, y: centre.y - dy * half)
let edge = CGPoint(x: centre.x + dx * half, y: centre.y + dy * half)
let chisel = profiledChisel(from: butt, to: edge, width: chiselWidth, profile: chiselProfile, skew: chiselSkew)

let shapes = composed([left, right, chisel], in: rect)
writeIconLayer([shapes[0], shapes[1]], to: "Inscribe/AppIcon.icon/Assets/marks.svg")
writeIconLayer([shapes[2]], to: "Inscribe/AppIcon.icon/Assets/chisel.svg")

// MARK: - The menu bar

// Template images, which the menu bar tints for light and dark, so only the alpha
// counts. At rest the marks are solid and the chisel lighter, with a gap cut where
// it crosses them so it reads as lying over them. While a dictation is heard, the
// same N is knocked out of a filled tile: the app icon in miniature.

let marksPath = CGMutablePath()
marksPath.addPath(shapes[0].cgPath)
marksPath.addPath(shapes[1].cgPath)
let chiselShape = shapes[2].cgPath
let glyphBox = marksPath.boundingBoxOfPath.union(chiselShape.boundingBoxOfPath)

/// The N's `path` scaled so the whole N is `height` tall, centred on `centre`.
func placed(_ path: CGPath, height: CGFloat, centre: CGPoint) -> CGPath {
    let s = height / glyphBox.height
    var t = CGAffineTransform(translationX: centre.x, y: centre.y)
        .scaledBy(x: s, y: s)
        .translatedBy(x: -glyphBox.midX, y: -glyphBox.midY)
    return path.copy(using: &t)!
}

/// The marks with a `gap` cut around the chisel.
func cut(_ marks: CGPath, around chisel: CGPath, gap: CGFloat) -> CGPath {
    let clearance = chisel.copy(strokingWithWidth: gap * 2, lineCap: .round, lineJoin: .round, miterLimit: 10).union(chisel)
    return marks.subtracting(clearance)
}

let menuWidth = max((glyphBox.width * menuHeight / glyphBox.height).rounded(.up), menuHeight)
let menuCentre = CGPoint(x: menuWidth / 2, y: menuHeight / 2)
let catalog = "Inscribe/Helpers/Assets.xcassets"

let restingMarks = placed(marksPath, height: menuHeight, centre: menuCentre)
let restingChisel = placed(chiselShape, height: menuHeight, centre: menuCentre)
writeSVG([(cut(restingMarks, around: restingChisel, gap: menuGap), 1), (restingChisel, menuChiselAlpha)],
         width: menuWidth, height: menuHeight, fill: "#000000", digits: 3,
         to: "\(catalog)/MenuBarIcon.imageset/MenuBarIcon.svg")

let tile = CGPath(roundedRect: CGRect(x: menuCentre.x - menuHeight / 2, y: 0, width: menuHeight, height: menuHeight),
                  cornerWidth: menuHeight * menuTileRadius, cornerHeight: menuHeight * menuTileRadius, transform: nil)
let tileMarks = placed(marksPath, height: menuHeight * menuTileGlyph, centre: menuCentre)
let tileChisel = placed(chiselShape, height: menuHeight * menuTileGlyph, centre: menuCentre)
let tileFilled = tile.subtracting(cut(tileMarks, around: tileChisel, gap: menuGap * menuTileGlyph)).subtracting(tileChisel)
writeSVG([(tileFilled, 1), (tileChisel, 1 - menuChiselAlpha)],
         width: menuWidth, height: menuHeight, fill: "#000000", digits: 3,
         to: "\(catalog)/MenuBarIconSpeaking.imageset/MenuBarIconSpeaking.svg")

print("Wrote the icon's layers and the menu bar images")
