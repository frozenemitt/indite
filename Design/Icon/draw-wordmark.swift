// The ribbon in the README's wordmark, drawn by the app's own rules.
//
// The ribbon is the one in the dictation panel, ListeningBar.swift: 48 bands through
// one curve, tapered at both ends, a resting line, two blurred glows and, in light
// mode, a deep azure edge. The numbers below are copied from that file. Change them
// together, or the wordmark stops matching the app. Only the band is taller than the
// app's, so the swell reads at README size; the line, the glows and the edge grow with it.
//
// The motion is wordmark-motion.json: 82 frames of 48 amplitudes, played over 6.8
// seconds. Each frame is what the app would draw for one moment of a voice.
//
//     swift Design/Icon/draw-wordmark.swift
//
// from the repository's root rewrites the ribbon in Docs/Images/wordmark-light.svg and
// wordmark-dark.svg, and leaves the tile, the cursor and the name alone.

import Foundation

// ListeningBar.swift, in points.
let bandHeight = 22.0
let bandMargin = 2.0                   // kept clear above and below the swell
let restingThickness = 1.2
let darkGlows = (wide: 11.0, tight: 3.0)
let lightGlows = (wide: 12.0, tight: 3.5)
let glowOpacities = (wide: 0.45, tight: 0.9)
let azure = "#3D99FF", violet = "#9E61FF", deepAzure = "#1A6BF2"
let voiceStops: [(Double, String, Double)] = [
    (0.0, violet, 0.4), (0.16, violet, 1), (0.36, azure, 1), (0.47, "#FFFFFF", 1),
    (0.53, "#FFFFFF", 1), (0.64, azure, 1), (0.84, violet, 1), (1.0, violet, 0.4)
]
let haloStops: [(Double, String, Double)] = [
    (0.0, violet, 0.5), (0.2, violet, 1), (0.5, azure, 1), (0.8, violet, 1), (1.0, violet, 0.5)
]

// The wordmark: tile units, 100 to the tile's side, with the ribbon twice the tile's width.
let ribbonStart = -50.0, ribbonLength = 200.0, centreLine = 50.0
let pointsToUnits = ribbonLength / 424    // the app's ribbon is 424 pt long
let bandScale = 3.0                       // the band is three times the app's height for its length
let blurToDeviation = 0.9                 // a SwiftUI blur radius as an SVG standard deviation, measured
let duration = "6.8s"

func taper(_ index: Int, of count: Int) -> Double {
    let width = Double(count) / 4
    let distance = Double(min(index, count - 1 - index))
    return distance >= width ? 1 : 0.5 - 0.5 * cos(.pi * distance / width)
}

func f(_ value: Double, _ places: Int) -> String { String(format: "%.\(places)f", value) }

/// The app's outline: quadratic curves through the band points, mirrored about the centre.
func outline(_ amplitudes: [Double], top: Double, height: Double, resting: Double) -> String {
    let count = amplitudes.count
    let middle = height / 2
    let reach = middle - bandMargin * (height / bandHeight)
    let step = ribbonLength / Double(count - 1)
    let upper = amplitudes.enumerated().map { index, value in
        (ribbonStart + Double(index) * step,
         top + middle - (resting + (reach - resting) * value) * taper(index, of: count))
    }
    let lower = upper.reversed().map { ($0.0, top + middle + (top + middle - $0.1)) }

    func run(_ points: [(Double, Double)], starting: Bool) -> String {
        var out = (starting ? "M" : "L") + "\(f(points[0].0, 1)) \(f(points[0].1, 1))"
        for (current, next) in zip(points, points.dropFirst()) {
            out += "Q\(f(current.0, 1)) \(f(current.1, 1)) \(f((current.0 + next.0) / 2, 1)) \(f((current.1 + next.1) / 2, 1))"
        }
        return out + "L\(f(points[points.count - 1].0, 1)) \(f(points[points.count - 1].1, 1))"
    }
    return run(upper, starting: true) + run(lower, starting: false) + "Z"
}

/// The light mode edge, heavier while the ribbon lies flat.
func edgeWidth(_ amplitudes: [Double]) -> Double {
    let flatness = min(max((0.4 - amplitudes.max()!) / 0.3, 0), 1)
    return 0.75 + 0.45 * flatness
}

func stops(_ list: [(Double, String, Double)]) -> String {
    list.map { offset, color, opacity in
        "<stop offset=\"\(offset)\" stop-color=\"\(color)\"" + (opacity != 1 ? " stop-opacity=\"\(opacity)\"" : "") + "/>"
    }.joined()
}

func ribbon(_ frames: [[Double]], dark: Bool) -> (defs: String, body: String) {
    let scale = pointsToUnits * bandScale
    let height = bandHeight * scale
    let top = centreLine - bandHeight * pointsToUnits * bandScale / 2
    let resting = restingThickness * scale
    let outlines = frames.map { outline($0, top: top, height: height, resting: resting) }
    let edges = frames.map { edgeWidth($0) * scale }
    let glows = dark ? darkGlows : lightGlows
    let wide = glows.wide * scale * blurToDeviation, tight = glows.tight * scale * blurToDeviation

    func region(_ deviation: Double) -> String {
        let pad = 4 * deviation
        return "filterUnits=\"userSpaceOnUse\" x=\"\(f(ribbonStart - pad, 2))\" y=\"\(f(top - pad, 2))\" width=\"\(f(ribbonLength + 2 * pad, 2))\" height=\"\(f(height + 2 * pad, 2))\""
    }
    let vertical = "gradientUnits=\"userSpaceOnUse\" x1=\"0\" y1=\"\(f(top, 2))\" x2=\"0\" y2=\"\(f(top + height, 2))\""
    let defs = "<linearGradient id=\"ribbonFill\" \(vertical)>\(stops(voiceStops))</linearGradient>"
        + "<linearGradient id=\"ribbonHalo\" \(vertical)>\(stops(haloStops))</linearGradient>"
        + "<linearGradient id=\"ribbonEdge\" gradientUnits=\"userSpaceOnUse\" x1=\"\(f(ribbonStart, 2))\" y1=\"0\" x2=\"\(f(ribbonStart + ribbonLength, 2))\" y2=\"0\">"
        + "<stop offset=\"0\" stop-color=\"\(deepAzure)\" stop-opacity=\"0\"/><stop offset=\"0.22\" stop-color=\"\(deepAzure)\" stop-opacity=\"0.85\"/>"
        + "<stop offset=\"0.78\" stop-color=\"\(deepAzure)\" stop-opacity=\"0.85\"/><stop offset=\"1\" stop-color=\"\(deepAzure)\" stop-opacity=\"0\"/></linearGradient>"
        + "<filter id=\"ribbonWide\" \(region(wide))><feGaussianBlur stdDeviation=\"\(f(wide, 2))\"/></filter>"
        + "<filter id=\"ribbonTight\" \(region(tight))><feGaussianBlur stdDeviation=\"\(f(tight, 2))\"/></filter>"

    // Every drawn copy carries its own animated outline. Safari repaints a <use> of an
    // animated path only around the path, so a blurred copy left stale glow as stripes.
    let animation = "<animate attributeName=\"d\" dur=\"\(duration)\" repeatCount=\"indefinite\" calcMode=\"linear\" values=\"\(outlines.joined(separator: ";"))\"/>"
    func copy(_ attributes: String, _ extra: String = "") -> String {
        "<path d=\"\(outlines[0])\" \(attributes)>\(animation)\(extra)</path>"
    }

    var layers: String
    if dark {
        // Light added to light, as the app's plusLighter inside its compositing group.
        layers = copy("fill=\"url(#ribbonFill)\" filter=\"url(#ribbonWide)\" opacity=\"\(glowOpacities.wide)\" style=\"mix-blend-mode:plus-lighter\"")
            + copy("fill=\"url(#ribbonFill)\" filter=\"url(#ribbonTight)\" opacity=\"\(glowOpacities.tight)\" style=\"mix-blend-mode:plus-lighter\"")
            + copy("fill=\"url(#ribbonFill)\"")
    } else {
        let widths = edges.map { f($0, 2) }.joined(separator: ";")
        layers = copy("fill=\"url(#ribbonHalo)\" filter=\"url(#ribbonWide)\" opacity=\"\(glowOpacities.wide)\"")
            + copy("fill=\"url(#ribbonHalo)\" filter=\"url(#ribbonTight)\" opacity=\"\(glowOpacities.tight)\"")
            + copy("fill=\"url(#ribbonFill)\"")
            + copy("fill=\"none\" stroke=\"url(#ribbonEdge)\" stroke-width=\"\(f(edges[0], 2))\"",
                   "<animate attributeName=\"stroke-width\" dur=\"\(duration)\" repeatCount=\"indefinite\" calcMode=\"linear\" values=\"\(widths)\"/>")
    }
    return (defs, "<g style=\"isolation:isolate\">\(layers)</g>")
}

let motion = try JSONDecoder().decode([[Double]].self, from: Data(contentsOf: URL(fileURLWithPath: "Design/Icon/wordmark-motion.json")))

for (name, dark) in [("light", false), ("dark", true)] {
    let url = URL(fileURLWithPath: "Docs/Images/wordmark-\(name).svg")
    var lines = try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n")
    let (defs, body) = ribbon(motion, dark: dark)
    guard let defsLine = lines.firstIndex(where: { $0.hasPrefix("<linearGradient id=\"ribbonFill\"") }),
          let bodyLine = lines.firstIndex(where: { $0.hasPrefix("<g style=\"isolation:isolate\">") })
    else { fatalError("wordmark-\(name).svg has no ribbon to replace") }
    lines[defsLine] = defs
    lines[bodyLine] = body
    try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    print("wrote", url.path)
}
