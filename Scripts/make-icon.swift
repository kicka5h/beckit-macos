#!/usr/bin/env swift
//
// Draws the Beckit app icon and packages it as Beckit.icns.
//
// The mark is a bookmark ribbon whose tail forks into two uneven tails: a
// bookmark at a glance, a branch on second look, which is the whole app —
// writing, and every version of it. One shape, no text, no gradient inside the
// mark, so it still reads at 16pt in the Dock and the menu bar.
//
// Cream on ink, because that is what the app is for.
//
// Artwork is drawn full-bleed. macOS 26 masks app icons to the system shape
// itself, so an icon that ships its own rounded rectangle and padding ends up
// inset twice and visibly smaller than everything beside it in the Dock.
//
// Usage: Scripts/make-icon.swift [output-directory]

import AppKit
import CoreGraphics
import Foundation

// MARK: - Palette

let inkTop = CGColor(red: 0.38, green: 0.43, blue: 1.00, alpha: 1)      // periwinkle
let inkBottom = CGColor(red: 0.11, green: 0.12, blue: 0.42, alpha: 1)   // deep indigo
let paper = CGColor(red: 1.00, green: 0.97, blue: 0.92, alpha: 1)       // warm cream

// MARK: - Drawing

/// Draws the icon into `context` on a `size` × `size` canvas.
///
/// Everything is expressed as a fraction of the canvas so the same code renders
/// every size in the iconset without a second set of hand-tuned numbers.
func drawIcon(in context: CGContext, size: CGFloat) {
    let unit = size / 1024

    // Background: a full-bleed vertical gradient. Lighter at the top so the
    // icon reads with a light source above it, the way the rest of the system
    // material does.
    let space = CGColorSpaceCreateDeviceRGB()
    if let gradient = CGGradient(
        colorsSpace: space, colors: [inkTop, inkBottom] as CFArray, locations: [0, 1]) {
        context.drawLinearGradient(
            gradient,
            start: CGPoint(x: 0, y: size),
            end: CGPoint(x: size, y: 0),
            options: [])
    }

    // Specular highlight: the soft top-left sheen that makes the surface look
    // like a material rather than a swatch.
    context.saveGState()
    if let sheen = CGGradient(
        colorsSpace: space,
        colors: [
            CGColor(red: 1, green: 1, blue: 1, alpha: 0.30),
            CGColor(red: 1, green: 1, blue: 1, alpha: 0),
        ] as CFArray,
        locations: [0, 1]) {
        context.drawRadialGradient(
            sheen,
            startCenter: CGPoint(x: size * 0.24, y: size * 0.86), startRadius: 0,
            endCenter: CGPoint(x: size * 0.24, y: size * 0.86), endRadius: size * 0.72,
            options: [])
    }
    context.restoreGState()

    // The mark, in a top-left coordinate system so the geometry reads the way
    // it is drawn on paper. Core Graphics is bottom-left, hence the flip.
    func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
        CGPoint(x: x * unit, y: size - y * unit)
    }

    /// One bookmark ribbon: rounded shoulders, symmetric notch.
    func ribbon(offsetX: CGFloat, offsetY: CGFloat) -> CGPath {
        let left = 402 + offsetX
        let right = 662 + offsetX
        let top = 322 + offsetY
        let tail = 788 + offsetY
        let notch = 702 + offsetY
        let shoulder: CGFloat = 30

        let path = CGMutablePath()
        path.move(to: point(left, top + shoulder))
        path.addQuadCurve(to: point(left + shoulder, top), control: point(left, top))
        path.addLine(to: point(right - shoulder, top))
        path.addQuadCurve(to: point(right, top + shoulder), control: point(right, top))
        path.addLine(to: point(right, tail))
        path.addLine(to: point((left + right) / 2, notch))
        path.addLine(to: point(left, tail))
        path.closeSubpath()
        return path
    }

    // Three ribbons receding up and to the left: a bookmark, and behind it the
    // versions it has been through. The stack is what makes the mark specific
    // to this app rather than to every reading app ever made — and unlike a
    // lopsided tail, an offset stack reads as deliberate at any size.
    //
    // Drawn back to front so the nearer ribbon overlaps the one behind it.
    let layers: [(dx: CGFloat, dy: CGFloat, alpha: CGFloat)] = [
        (-84, -72, 0.24),
        (-42, -36, 0.50),
        (0, 0, 1.0),
    ]
    let paths = layers.map { ribbon(offsetX: $0.dx, offsetY: $0.dy) }

    // Fit the composition rather than positioning it by hand: measure what the
    // three ribbons actually occupy, then centre that and scale it to a fixed
    // share of the canvas. Adjusting an offset above can no longer knock the
    // mark off centre, and every size in the iconset lands identically.
    let bounds = paths.dropFirst().reduce(paths[0].boundingBoxOfPath) {
        $0.union($1.boundingBoxOfPath)
    }
    // 62% leaves the margin macOS 26's icon mask expects. Artwork that runs
    // closer to the edge gets clipped by the system's rounded shape.
    let scale = (size * 0.62) / bounds.height

    context.saveGState()
    // Optical, not geometric, centring. The solid front ribbon carries nearly
    // all the visual weight and sits down-right within the group, so a
    // mathematically centred bounding box reads as leaning that way. Nudging
    // the group back up-left puts the ribbon where the eye expects it.
    context.translateBy(x: size / 2 - size * 0.022, y: size / 2 + size * 0.018)
    context.scaleBy(x: scale, y: scale)
    context.translateBy(x: -bounds.midX, y: -bounds.midY)

    for (layer, path) in zip(layers, paths) {
        context.saveGState()

        if layer.alpha == 1 {
            // Only the front ribbon casts a shadow. Shadowing every layer
            // muddies the gaps and the stack stops reading as separate sheets.
            context.setShadow(
                offset: CGSize(width: 0, height: -14 * unit),
                blur: 34 * unit,
                color: CGColor(red: 0.04, green: 0.04, blue: 0.18, alpha: 0.40))
        }
        context.setFillColor(paper.copy(alpha: layer.alpha) ?? paper)
        context.addPath(path)
        context.fillPath()
        context.restoreGState()

        // A barely-there vertical gradient down the front ribbon, laid over the
        // solid fill so the fill is what casts the shadow. Flat cream reads as
        // a sticker; a graded surface reads as lit, which is the premise of the
        // whole material.
        guard layer.alpha == 1 else { continue }
        context.saveGState()
        context.addPath(path)
        context.clip()
        let box = path.boundingBoxOfPath
        if let warm = CGGradient(
            colorsSpace: space,
            colors: [paper, CGColor(red: 0.96, green: 0.91, blue: 0.84, alpha: 1)] as CFArray,
            locations: [0, 1]) {
            context.drawLinearGradient(
                warm,
                start: CGPoint(x: box.midX, y: box.maxY),
                end: CGPoint(x: box.midX, y: box.minY),
                options: [])
        }
        context.restoreGState()
    }

    context.restoreGState()
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
