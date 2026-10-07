// The app icon's shape, and the menu bar's.
//
// The I-beam text cursor: one stem, and two arms at each end that curve into it. This
// draws the cursor as a filled outline and writes it as the SVG layer of the Icon
// Composer document, and draws it small for the menu bar. The tile, the glass and the
// opacity live in the document's icon.json, which Icon Composer edits; nothing here
// touches them.
//
//     swift Design/Icon/draw-icon.swift
//
// from the repository's root writes cursor.svg into Indite/AppIcon.icon/Assets, and
// the two menu bar images into the asset catalog.

import CoreGraphics
import Foundation

// The design, as settled on 2026-10-07, in a tile 100 units to a side with y running
// down. The numbers are the cursor's centre line; the stroke is drawn around it.
let armHeights: [(y: CGFloat, direction: CGFloat)] = [(18, 1), (82, -1)]
let stemX: CGFloat = 50
let armReach: CGFloat = 11.5        // from the stem to an arm's tip
let bendAlong: CGFloat = 6          // where an arm starts to curve, measured from the stem
let bendDown: CGFloat = 8.5         // how far along the stem the curve ends
let strokeWidth: CGFloat = 5.6
let iconScale: CGFloat = 0.92       // the cursor in the tile, about the tile's centre
let kappa: CGFloat = 0.5523         // a quarter ellipse from one cubic curve

// The menu bar's images, in points. Both are square so the status item keeps its width
// when the image changes.
let menuSize: CGFloat = 16
let menuStroke: CGFloat = 1.5       // the cursor at rest, as tall as the image
let tileGlyph: CGFloat = 0.70       // the cursor's height in the dictation tile, as a share of it
let tileStroke: CGFloat = 1.3
let tileRadius: CGFloat = 0.225     // the tile's corner radius, as a share of its side

// MARK: - The cursor

/// The centre line: four arms, each running in from its tip and curving into the stem.
func centreLine() -> CGPath {
    let path = CGMutablePath()
    for arm in armHeights {
        let join = arm.y + arm.direction * bendDown
        for side: CGFloat in [-1, 1] {
            path.move(to: CGPoint(x: stemX + side * armReach, y: arm.y))
            path.addLine(to: CGPoint(x: stemX + side * bendAlong, y: arm.y))
            path.addCurve(to: CGPoint(x: stemX, y: join),
                          control1: CGPoint(x: stemX + side * bendAlong * (1 - kappa), y: arm.y),
                          control2: CGPoint(x: stemX, y: join - arm.direction * bendDown * kappa))
        }
    }
    path.move(to: CGPoint(x: stemX, y: armHeights[0].y + bendDown))
    path.addLine(to: CGPoint(x: stemX, y: armHeights[1].y - bendDown))
    return path
}

/// The cursor as one filled outline: the centre line stroked `width` wide with round
/// ends, its overlapping pieces merged.
func outline(width: CGFloat) -> CGPath {
    centreLine()
        .copy(strokingWithWidth: width, lineCap: .round, lineJoin: .round, miterLimit: 10)
        .normalized()
}

/// The cursor `height` tall overall with a stroke `stroke` wide, centred on `centre`.
func placed(height: CGFloat, stroke: CGFloat, centre: CGPoint) -> CGPath {
    let span = armHeights[1].y - armHeights[0].y
    let scale = (height - stroke) / span
    var move = CGAffineTransform(translationX: centre.x, y: centre.y)
        .scaledBy(x: scale, y: scale)
        .translatedBy(x: -stemX, y: -50)
    return outline(width: stroke / scale).copy(using: &move)!
}

// MARK: - Writing

/// A path as SVG path data. The drawing already runs y down, as SVG does.
func svgData(_ path: CGPath, digits: Int) -> String {
    var d = ""
    let format = "%.\(digits)f %.\(digits)f"
    path.applyWithBlock { element in
        let p = element.pointee.points
        func f(_ q: CGPoint) -> String { String(format: format, q.x, q.y) }
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

/// One path as an SVG `side` points square, filled with `fill`. Even-odd, so a shape
/// cut out of another stays a hole.
func writeSVG(_ path: CGPath, side: CGFloat, fill: String, digits: Int, to file: String) {
    let s = String(format: "%g", side)
    let body = """
        <svg xmlns="http://www.w3.org/2000/svg" width="\(s)" height="\(s)" viewBox="0 0 \(s) \(s)">
          <path d="\(svgData(path, digits: digits))" fill="\(fill)" fill-rule="evenodd"/>
        </svg>

        """
    try! body.write(toFile: file, atomically: true, encoding: .utf8)
}

// MARK: - The icon

var toIcon = CGAffineTransform(scaleX: 10.24, y: 10.24)
    .translatedBy(x: 50, y: 50)
    .scaledBy(x: iconScale, y: iconScale)
    .translatedBy(x: -50, y: -50)
writeSVG(outline(width: strokeWidth).copy(using: &toIcon)!, side: 1024, fill: "#FFFFFF", digits: 2,
         to: "Indite/AppIcon.icon/Assets/cursor.svg")

// MARK: - The menu bar

// Template images, which the menu bar tints for light and dark, so only the shape
// counts. At rest the cursor stands alone; while a dictation is heard it is cut out of
// a filled tile.

let catalog = "Indite/Helpers/Assets.xcassets"
let middle = CGPoint(x: menuSize / 2, y: menuSize / 2)

writeSVG(placed(height: menuSize, stroke: menuStroke, centre: middle), side: menuSize, fill: "#000000", digits: 3,
         to: "\(catalog)/MenuBarIcon.imageset/MenuBarIcon.svg")

let corner = menuSize * tileRadius
let tile = CGPath(roundedRect: CGRect(x: 0, y: 0, width: menuSize, height: menuSize),
                  cornerWidth: corner, cornerHeight: corner, transform: nil)
let knockedOut = tile.subtracting(placed(height: menuSize * tileGlyph, stroke: tileStroke, centre: middle))
writeSVG(knockedOut, side: menuSize, fill: "#000000", digits: 3,
         to: "\(catalog)/MenuBarIconSpeaking.imageset/MenuBarIconSpeaking.svg")

print("Wrote the icon's layer and the menu bar images")
