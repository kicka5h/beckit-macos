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
let groundTop = CGColor(red: 1.000, green: 1.000, blue: 1.000, alpha: 1)
let groundBottom = CGColor(red: 0.976, green: 0.969, blue: 0.973, alpha: 1)

// MARK: - Geometry
//
// Everything below is expressed in a 1024-unit design space with the origin at
// the top left, so the numbers read the way the shape is drawn on paper. The
// same geometry renders every size in the iconset.

private enum Design {
    static let canvas: CGFloat = 1024
    static let centerX: CGFloat = 512
    static let opticalOffsetY: CGFloat = 15

    // Covers: two verticals joined by one continuous base. The base runs
    // unbroken under the gutter, which is both what the reference does and what
    // keeps the pencil from breaking the book's outline.
    static let outerLeft: CGFloat = 210
    static let outerRight: CGFloat = 814
    static let coverTop: CGFloat = 283
    static let coverBottom: CGFloat = 645
    static let baseControl: CGFloat = 765   // depth of the base curve
    static let baseInset: CGFloat = 74     // pulled in, so the sides don't bow

    // Page top edges. Each lifts off its cover into a hump, then falls to the
    // pencil — the two humps and the dip between them are the silhouette the
    // reference reads by.
    static let pageControl1 = CGPoint(x: 272, y: 251)
    static let pageControl2 = CGPoint(x: 382, y: 305)

    // Pencil, nested in the gutter, its sides continuing the page edges.
    static let pencilLeft: CGFloat = 467
    static let pencilRight: CGFloat = 557
    static let pencilTop: CGFloat = 343
    static let shoulder: CGFloat = 566      // where the barrel starts tapering
    static let tip: CGFloat = 665
    static let graphite: CGFloat = 600      // the line across the sharpened end

    /// The lowest point of the base, at the gutter — the midpoint of a cubic
    /// whose ends share a height and whose controls share a depth.
    static var baseAtGutter: CGFloat { (coverBottom + 3 * baseControl) / 4 }
}

/// The stroke weight in **pixels** for a given rendered size.
///
/// A single relative weight cannot serve both ends of the iconset. The mark is
/// drawn at 46/1024 of the canvas, which is right from 256pt up — and at 16pt
/// works out to well under a pixel, so antialiasing spreads it into pale grey
/// and the icon reads as a smudge. Below 256 the weight is therefore floored at
/// what a line actually needs to hold its colour.
///
/// Returned in pixels, not design units, precisely because that floor is a
/// statement about pixels: expressing it as a ratio is what hid the problem.
func strokePixels(for pixelSize: CGFloat) -> CGFloat {
    let natural = 46 / 1024 * pixelSize
    let minimum: CGFloat = switch pixelSize {
    case ..<24: 1.8
    case ..<48: 2.6
    case ..<96: 3.6
    case ..<192: 5.0
    default: 0
    }
    return max(natural, minimum)
}

// MARK: - Drawing

func drawIcon(in context: CGContext, size: CGFloat) {
    // The pencil must stay inside the book. Not a stylistic preference: a shaft
    // with a point emerging below two forms that splay away from it makes a
    // silhouette nobody wants on their Dock, and it is one nudged constant
    // away. Fail the build instead of relying on anyone noticing.
    precondition(
        Design.tip < Design.baseAtGutter,
        "the pencil tip (\(Design.tip)) must sit above the base at the gutter "
            + "(\(Design.baseAtGutter)) — nothing may protrude below the book")

    let unit = size / Design.canvas

    /// Design space (top-left origin) to Core Graphics space (bottom-left).
    func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
        CGPoint(x: x * unit, y: size - (y + Design.opticalOffsetY) * unit)
    }

    // Ground: full bleed, near-white, with just enough gradient to keep it from
    // reading as a flat swatch.
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

    // Covers and base as one stroke: down the left cover, across the bottom, up
    // the right. Drawn continuously so the bottom corners get their curve
    // without a corner radius anywhere in the code.
    let frame = CGMutablePath()
    frame.move(to: point(Design.outerLeft, Design.coverTop))
    frame.addLine(to: point(Design.outerLeft, Design.coverBottom))
    frame.addCurve(
        to: point(Design.outerRight, Design.coverBottom),
        control1: point(Design.outerLeft + Design.baseInset, Design.baseControl),
        control2: point(Design.outerRight - Design.baseInset, Design.baseControl))
    frame.addLine(to: point(Design.outerRight, Design.coverTop))

    /// One page's top edge, continuing into that side of the pencil and down to
    /// the point. Page and pencil are a single unbroken line — that shared
    /// contour is the idea of the mark, and splitting them loses it.
    func page(mirrored: Bool) -> CGPath {
        func x(_ value: CGFloat) -> CGFloat {
            mirrored ? 2 * Design.centerX - value : value
        }
        let path = CGMutablePath()
        path.move(to: point(x(Design.outerLeft), Design.coverTop))
        path.addCurve(
            to: point(x(Design.pencilLeft), Design.pencilTop),
            control1: point(x(Design.pageControl1.x), Design.pageControl1.y),
            control2: point(x(Design.pageControl2.x), Design.pageControl2.y))
        path.addLine(to: point(x(Design.pencilLeft), Design.shoulder))
        path.addLine(to: point(Design.centerX, Design.tip))
        return path
    }

    context.setStrokeColor(ink)
    context.setLineCap(.round)
    context.setLineJoin(.round)
    context.setLineWidth(strokePixels(for: size))

    context.addPath(frame)
    context.addPath(page(mirrored: false))
    context.addPath(page(mirrored: true))
    context.strokePath()

    // The graphite line across the sharpened end. Below 64pt the taper is a few
    // pixels wide and this lands as a blot — a detail that cannot be resolved
    // is worse than no detail.
    guard size >= 64 else { return }

    let inset = (Design.graphite - Design.shoulder) / (Design.tip - Design.shoulder)
        * (Design.centerX - Design.pencilLeft)

    let graphite = CGMutablePath()
    graphite.move(to: point(Design.pencilLeft + inset, Design.graphite))
    graphite.addLine(to: point(Design.pencilRight - inset, Design.graphite))

    // Lighter than the outline. At full weight this short segment reads as a
    // blob wedged between the taper lines rather than a division.
    context.setLineWidth(strokePixels(for: size) * 0.7)
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
