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
    static let opticalOffsetY: CGFloat = 25

    // The book is built as two mirrored halves rather than one outline. A
    // single silhouette running under the spine reads as a container — a bowl
    // with a slot — because nothing separates the left side from the right.
    // Each half here has its own top edge, fore edge, page line and cover, so
    // the two sides of the opening are distinct shapes.
    static let outerLeft: CGFloat = 205
    static let outerRight: CGFloat = 819

    // Each half is a page block: a top surface, a fore edge, and a bottom that
    // runs back in to the spine. Top and bottom both slope *down* toward the
    // gutter, which is what an open book does and what makes the block read as
    // a leaf with thickness rather than as one side of a container.
    static let topOuter: CGFloat = 300
    static let bottomOuter: CGFloat = 570

    // The page stack: a line parallel to the bottom edge and above it, so the
    // fore edge shows a band of paper under the top sheet. The band has to
    // clear the stroke on both sides or the two lines merge into one rule.
    static let pageLineOuter: CGFloat = 498
    static let pageLineInner: CGFloat = 512

    // Page top edge: lifts a little off the fore edge before falling to the
    // spine, which is what gives the pages their fan.
    static let pageControl1 = CGPoint(x: 272, y: 268)
    static let pageControl2 = CGPoint(x: 382, y: 322)

    // Pencil. Wide enough that the barrel holds an open channel between its two
    // sides — squeeze it any narrower and the stroke closes the gap, leaving a
    // sliver that reads as the seam between the pages rather than as a pencil.
    static let pencilLeft: CGFloat = 452
    static let pencilRight: CGFloat = 572
    static let pencilTop: CGFloat = 366
    static let shoulder: CGFloat = 578      // where the barrel starts tapering
    static let tip: CGFloat = 700
    static let graphite: CGFloat = 612      // the line across the sharpened end

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

    /// One half of the book, mirrored for the other side.
    ///
    /// Two strokes. The first is the page surface running from the fore edge
    /// into that side of the pencil and down to the point — page and pencil
    /// share one unbroken contour, which is the idea of the mark. The second is
    /// the fore edge and cover, which give the half a body instead of leaving
    /// it an open curve.
    func half(mirrored: Bool) -> [CGPath] {
        func x(_ value: CGFloat) -> CGFloat {
            mirrored ? 2 * Design.centerX - value : value
        }

        /// A curve running from the fore edge in to the spine, bellying by
        /// `sag` on the way.
        ///
        /// Every horizontal in the mark uses this, which is what keeps the page
        /// surface, the stack line and the block's bottom parallel. Deep sags
        /// were the earlier mistake: they swing the ends outward and the two
        /// halves stop reading as page blocks and start reading as wings.
        func leaf(from outer: CGFloat, to inner: CGFloat, sag: CGFloat) -> CGMutablePath {
            let path = CGMutablePath()
            path.move(to: point(x(Design.outerLeft), outer))
            path.addCurve(
                to: point(x(Design.pencilLeft), inner),
                control1: point(x(Design.outerLeft + 96), outer + sag),
                control2: point(x(Design.pencilLeft - 104), inner + sag * 0.7))
            return path
        }

        // Page surface, flowing into that side of the pencil and down to the
        // point. Page and pencil share one unbroken contour — that is the idea
        // of the mark.
        let surface = leaf(from: Design.topOuter, to: Design.pencilTop, sag: -6)
        surface.addLine(to: point(x(Design.pencilLeft), Design.shoulder))
        surface.addLine(to: point(Design.centerX, Design.tip))

        // Fore edge, then the block's bottom. It ends where the barrel starts
        // to taper, so the block closes onto the pencil and leaves the point
        // protruding below the book rather than buried in the junction.
        let board = CGMutablePath()
        board.move(to: point(x(Design.outerLeft), Design.topOuter))
        board.addLine(to: point(x(Design.outerLeft), Design.bottomOuter))
        board.addPath(leaf(
            from: Design.bottomOuter, to: Design.shoulder, sag: 20))

        // The page stack: one sheet lifted off the block, so the fore edge
        // shows paper under the top sheet rather than a bare outline.
        //
        // Dropped below 32pt. There it is the third horizontal in a space a few
        // pixels tall, and all three merge into one grey bar — the mark reads
        // better as a plain open book than as a smudge with more information in
        // it than the pixels can carry.
        guard size >= 32 else { return [surface, board] }
        let pages = leaf(
            from: Design.pageLineOuter, to: Design.pageLineInner, sag: 20)

        return [surface, board, pages]
    }

    context.setStrokeColor(ink)
    context.setLineCap(.round)
    context.setLineJoin(.round)
    context.setLineWidth(strokePixels(for: size))

    for path in half(mirrored: false) + half(mirrored: true) {
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
