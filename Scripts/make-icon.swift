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
// can resolve. See `strokeWidth(for:)`.
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
    static let opticalOffsetY: CGFloat = 15

    // Outer covers. The top corners sit *higher* than the spine, so the page
    // edges slope inward and down — an open book seen face on. Curving them the
    // other way turns the whole mark into a bag with a slot in it.
    static let outerLeft: CGFloat = 210
    static let outerRight: CGFloat = 814
    static let coverTop: CGFloat = 283
    static let coverBottom: CGFloat = 645
    // Bottom edge. The controls are pulled *inward* from the covers as well as
    // down: placing them directly below the corners makes the sides bow out and
    // the book reads as a bowl.
    static let baseControl: CGFloat = 754
    static let baseControlInset: CGFloat = 74

    // Page top edge: lifts a little off the cover before falling to the spine,
    // which is what gives the pages their fan.
    static let pageControl1 = CGPoint(x: 272, y: 251)
    static let pageControl2 = CGPoint(x: 382, y: 305)

    // Pencil. Narrow enough to read as a pencil rather than a gap between the
    // pages — roughly 1:3.6 barrel, which is about where a pencil stops looking
    // like a crayon.
    static let pencilLeft: CGFloat = 467
    static let pencilRight: CGFloat = 557
    static let pencilTop: CGFloat = 343
    static let shoulder: CGFloat = 568      // where the barrel starts tapering
    static let tip: CGFloat = 673
    static let graphite: CGFloat = 608      // the line across the sharpened end
}

/// The stroke weight, in design units, for a given rendered pixel size.
///
/// A single relative weight cannot serve both ends of the iconset: at 1024 it
/// wants to be delicate, and at 16 that same ratio renders as a grey smudge.
/// This ramps the weight up as the canvas shrinks, which is what a type
/// designer would call optical sizing and what keeps the 16pt icon legible.
func strokeWidth(for pixelSize: CGFloat) -> CGFloat {
    let base: CGFloat = 46
    let t = min(max((256 - pixelSize) / (256 - 16), 0), 1)
    return base * (1 + 0.55 * t)
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

    // Covers and base, as one stroke: down the left cover, across the bottom,
    // up the right. Drawing it continuously is what gives the bottom corners
    // their curve without a corner radius anywhere in the code.
    let frame = CGMutablePath()
    frame.move(to: point(Design.outerLeft, Design.coverTop))
    frame.addLine(to: point(Design.outerLeft, Design.coverBottom))
    frame.addCurve(
        to: point(Design.outerRight, Design.coverBottom),
        control1: point(Design.outerLeft + Design.baseControlInset, Design.baseControl),
        control2: point(Design.outerRight - Design.baseControlInset, Design.baseControl))
    frame.addLine(to: point(Design.outerRight, Design.coverTop))

    /// One page's top edge, flowing into that side of the pencil and down to
    /// the tip. Page and pencil are a single unbroken line — that shared
    /// contour is the whole idea of the mark, and breaking it into separate
    /// shapes would lose it.
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
    context.setLineWidth(strokeWidth(for: size) * unit)

    context.addPath(frame)
    context.addPath(page(mirrored: false))
    context.addPath(page(mirrored: true))
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
    context.setLineWidth(strokeWidth(for: size) * 0.8 * unit)
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
