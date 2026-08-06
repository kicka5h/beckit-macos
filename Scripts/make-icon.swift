#!/usr/bin/env swift
//
// Draws the Beckit app icon and packages it as Beckit.icns.
//
// An open book whose spine is a pencil: the two things the app is for, sharing
// one line. Drawn as outlined strokes with round caps, pink on a near-white
// ground.
//
// Line-art icons are the hard case for an app icon, because a stroke that looks
// elegant at 512pt is under a pixel wide at 16pt in the menu bar. So the stroke
// weight here is optically sized — it thickens as the canvas shrinks — and the
// smallest sizes drop the pencil's graphite line, which is detail no 16pt icon
// can resolve. See `strokePixels(for:)`.
//
// Artwork is drawn full-bleed. macOS 26 masks app icons to the system shape
// itself, so an icon that ships its own rounded rectangle and padding ends up
// inset twice and sits visibly small in the Dock.
//
// Usage: Scripts/make-icon.swift [output-directory]

import AppKit
import CoreGraphics
import Foundation

// MARK: - Palette

let ink = CGColor(red: 0.839, green: 0.278, blue: 0.608, alpha: 1)      // pink
let groundTop = CGColor(red: 1.000, green: 0.980, blue: 0.990, alpha: 1)
let groundBottom = CGColor(red: 0.988, green: 0.914, blue: 0.953, alpha: 1)

// MARK: - Geometry
//
// Everything below is expressed in a 1024-unit design space with the origin at
// the top left, so the numbers read the way the shape is drawn on paper. The
// same geometry renders every size in the iconset.

private enum Design {
    static let canvas: CGFloat = 1024
    static let centerX: CGFloat = 512
    /// The mark's ink sits slightly above the middle of its own bounds — the
    /// heavy base is lower than the light page tops — so it needs nudging down
    /// to look centred in the tile.
    static let opticalOffsetY: CGFloat = 61

    static let outerLeft: CGFloat = 196
    static let outerRight: CGFloat = 828

    // Fore edges, and the two horizontals that close the book: a page stack
    // band sitting on a base. Both run unbroken from one fore edge to the
    // other.
    //
    // Nothing may extend below `base`. An earlier version let each half stop at
    // the gutter and put the pencil's point below the join — two forms splaying
    // away from a shaft with a tip. Read as a whole rather than as parts, that
    // silhouette was crude, and no amount of intent at the part level fixes a
    // silhouette. The base now closes across the bottom and the pencil is
    // wholly contained above it.
    static let topOuter: CGFloat = 250
    static let stackEdge: CGFloat = 520     // page band, at the fore edges
    static let stackSag: CGFloat = 56       // how far it dips at the gutter
    static let base: CGFloat = 596          // cover, at the fore edges
    static let baseSag: CGFloat = 62

    // Pencil, nested in the gutter. The tip stops well above where the base
    // dips, so the point never breaks the book's outline.
    static let pencilLeft: CGFloat = 469
    static let pencilRight: CGFloat = 555
    static let pencilTop: CGFloat = 320
    static let shoulder: CGFloat = 470      // where the barrel starts tapering
    static let tip: CGFloat = 540
    static let graphite: CGFloat = 505      // the line across the sharpened end

    /// The lowest point of the base, at the gutter. The pencil is checked
    /// against this so the two can never cross again.
    static var baseAtGutter: CGFloat { base + baseSag }

    /// Where the pencil's tapered edge sits at a given height, used to place the
    /// graphite line across the sharpened end.
    static func taperX(at y: CGFloat) -> CGFloat {
        pencilLeft + (y - shoulder) / (tip - shoulder) * (centerX - pencilLeft)
    }
}

/// The stroke weight in **pixels** for a given rendered size.
///
/// A single relative weight cannot serve both ends of the iconset. The mark is
/// drawn at 34/1024 of the canvas, which is right from 256pt up — and at 16pt
/// works out to 0.53 of a pixel, so antialiasing spreads it into pale grey and
/// the icon reads as a smudge. Below 256 the weight is therefore floored at
/// what a line actually needs to hold its colour, and the mark thickens as it
/// shrinks rather than fading out.
///
/// Returned in pixels, not design units, precisely because that floor is a
/// statement about pixels: expressing it as a ratio is what hid the problem.
func strokePixels(for pixelSize: CGFloat) -> CGFloat {
    let natural = 34 / 1024 * pixelSize
    let minimum: CGFloat = switch pixelSize {
    case ..<24: 1.6
    case ..<48: 2.2
    case ..<96: 3.0
    case ..<192: 4.2
    default: 0
    }
    return max(natural, minimum)
}

// MARK: - Drawing

func drawIcon(in context: CGContext, size: CGFloat) {
    // The pencil must stay inside the book. This is not a stylistic preference:
    // a shaft with a point emerging below two shapes that splay away from it
    // makes a silhouette nobody wants on their Dock, and it is easy to
    // reintroduce by nudging one number. Fail the build instead.
    precondition(
        Design.tip < Design.baseAtGutter,
        "the pencil tip (\(Design.tip)) must sit above the base at the gutter "
            + "(\(Design.baseAtGutter)) — nothing may protrude below the book")

    let unit = size / Design.canvas

    /// Design space (top-left origin) to Core Graphics space (bottom-left).
    func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
        CGPoint(x: x * unit, y: size - (y + Design.opticalOffsetY) * unit)
    }

    // Ground: full bleed, with just enough of a gradient to keep it from
    // reading as flat white.
    if let gradient = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [groundTop, groundBottom] as CFArray,
        locations: [0, 1]) {
        context.drawLinearGradient(
            gradient,
            start: CGPoint(x: 0, y: size),
            end: CGPoint(x: 0, y: 0),
            options: [])
    }

    /// A horizontal running the full width of the book, from one fore edge to
    /// the other, dipping by `sag` at the gutter.
    ///
    /// Unbroken on purpose. Stopping these at the gutter is what left a notch
    /// under the spine for the pencil to poke through.
    func spanning(_ y: CGFloat, sag: CGFloat) -> CGPath {
        let path = CGMutablePath()
        path.move(to: point(Design.outerLeft, y))
        path.addCurve(
            to: point(Design.outerRight, y),
            control1: point(Design.outerLeft + 168, y + sag),
            control2: point(Design.outerRight - 168, y + sag))
        return path
    }

    /// One page surface, running from its fore edge into that side of the
    /// pencil and down to the point. Page and pencil share one unbroken
    /// contour, which is the idea of the mark.
    func surface(mirrored: Bool) -> CGPath {
        func x(_ value: CGFloat) -> CGFloat {
            mirrored ? 2 * Design.centerX - value : value
        }
        let path = CGMutablePath()
        path.move(to: point(x(Design.outerLeft), Design.topOuter))
        path.addCurve(
            to: point(x(Design.pencilLeft), Design.pencilTop),
            control1: point(x(Design.outerLeft + 96), Design.topOuter - 6),
            control2: point(x(Design.pencilLeft - 104), Design.pencilTop - 4))
        path.addLine(to: point(x(Design.pencilLeft), Design.shoulder))
        path.addLine(to: point(Design.centerX, Design.tip))
        return path
    }

    /// Fore edge: the outer side of the book, from the page surface down to the
    /// base.
    func foreEdge(mirrored: Bool) -> CGPath {
        let edge = mirrored ? Design.outerRight : Design.outerLeft
        let path = CGMutablePath()
        path.move(to: point(edge, Design.topOuter))
        path.addLine(to: point(edge, Design.base))
        return path
    }

    var paths = [
        surface(mirrored: false), surface(mirrored: true),
        foreEdge(mirrored: false), foreEdge(mirrored: true),
        spanning(Design.base, sag: Design.baseSag),
    ]

    // The page stack band. Dropped below 32pt, where it is a third horizontal
    // in a space a few pixels tall and all of them merge into one grey bar —
    // the mark reads better as a plain open book than as a smudge carrying more
    // information than the pixels can hold.
    if size >= 32 {
        paths.append(spanning(Design.stackEdge, sag: Design.stackSag))
    }

    context.setStrokeColor(ink)
    context.setLineCap(.round)
    context.setLineJoin(.round)
    context.setLineWidth(strokePixels(for: size))

    for path in paths {
        context.addPath(path)
    }
    context.strokePath()

    // The graphite line across the sharpened end. Below 64pt the taper is only
    // a few pixels wide and this turns into a blot, so it is left off — a
    // detail that cannot be resolved is worse than no detail.
    guard size >= 64 else { return }

    let taper = (Design.tip - Design.shoulder)
    let inset = (Design.graphite - Design.shoulder) / taper
        * (Design.centerX - Design.pencilLeft)

    let graphite = CGMutablePath()
    graphite.move(to: point(Design.pencilLeft + inset, Design.graphite))
    graphite.addLine(to: point(Design.pencilRight - inset, Design.graphite))

    // Slightly lighter than the outline. At full weight this short segment
    // reads as a blob wedged between the taper lines rather than a division.
    context.setLineWidth(strokePixels(for: size) * 0.75)
    context.addPath(graphite)
    context.strokePath()
}

// MARK: - Rendering

func renderPNG(size: Int) -> Data {
    let dimension = CGFloat(size)
    guard let context = CGContext(
        data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { fatalError("could not create a \(size)pt context") }

    context.interpolationQuality = .high
    context.setAllowsAntialiasing(true)
    drawIcon(in: context, size: dimension)

    guard let image = context.makeImage() else { fatalError("could not render \(size)pt") }
    let representation = NSBitmapImageRep(cgImage: image)
    representation.size = NSSize(width: dimension, height: dimension)
    guard let data = representation.representation(using: .png, properties: [:]) else {
        fatalError("could not encode \(size)pt as PNG")
    }
    return data
}

// MARK: - Packaging

let arguments = CommandLine.arguments
let outputDirectory = URL(
    filePath: arguments.count > 1 ? arguments[1] : FileManager.default.currentDirectoryPath)
let iconset = outputDirectory.appending(path: "Beckit.iconset")

try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

// The sizes `iconutil` expects, as (point size, scale) pairs.
let variants: [(points: Int, scale: Int)] = [
    (16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2),
    (256, 1), (256, 2), (512, 1), (512, 2),
]

for variant in variants {
    let pixels = variant.points * variant.scale
    let suffix = variant.scale == 1 ? "" : "@\(variant.scale)x"
    let name = "icon_\(variant.points)x\(variant.points)\(suffix).png"
    try renderPNG(size: pixels).write(to: iconset.appending(path: name))
}

// A standalone 1024pt PNG, for the README and anywhere else the mark is needed.
try renderPNG(size: 1024).write(to: outputDirectory.appending(path: "Beckit-1024.png"))

let iconutil = Process()
iconutil.executableURL = URL(filePath: "/usr/bin/iconutil")
iconutil.arguments = [
    "--convert", "icns",
    "--output", outputDirectory.appending(path: "Beckit.icns").path(percentEncoded: false),
    iconset.path(percentEncoded: false),
]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else {
    FileHandle.standardError.write(Data("iconutil failed\n".utf8))
    exit(1)
}

try FileManager.default.removeItem(at: iconset)
print("Built \(outputDirectory.appending(path: "Beckit.icns").path(percentEncoded: false))")
