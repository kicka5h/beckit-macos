//
// Renders the Beckit app icon from the traced mark and packages it as
// Beckit.icns.
//
// The geometry is not written here. It lives in
// Sources/Beckit/Views/MarkGeometry.swift, traced from the reference artwork by
// Scripts/trace-reference.swift, and is compiled into both this generator and
// the app — so the icon in the Dock and the mark in the window are the same
// contours rather than two drawings kept in step by hand.
//
// Contours are filled with the even-odd rule: the holes in the mark are
// contours in their own right, and even-odd makes them holes for free.
//
// Line art is the hard case for an app icon, because strokes that look elegant
// at 512pt fall under a pixel at 16pt and antialias into pale grey. The fix
// here is to embolden — stroking the filled outline grows every edge outward by
// half the line width, thickening the mark uniformly without touching the
// geometry. See `embolden(for:)`.
//
// Artwork is full-bleed: macOS 26 masks app icons to the system shape itself,
// so an icon shipping its own rounded rectangle is inset twice and sits
// visibly small in the Dock.
//
// Build: swiftc -parse-as-library Scripts/make-icon.swift \
//            Sources/Beckit/Views/MarkGeometry.swift -o <tool>
// Usage: <tool> [output-directory]

import AppKit
import CoreGraphics
import Foundation

// MARK: - Palette

let ink = CGColor(red: 0.839, green: 0.278, blue: 0.608, alpha: 1)      // pink
let groundTop = CGColor(red: 1.000, green: 1.000, blue: 1.000, alpha: 1)
let groundBottom = CGColor(red: 0.976, green: 0.969, blue: 0.973, alpha: 1)

/// How much to thicken the mark, in pixels, at a given rendered size.
///
/// The reference's strokes are a small fraction of the canvas — right from
/// 128pt up, and well under one pixel at 16pt, where antialiasing spreads them
/// into pale grey and the icon reads as a smudge. Stroking the filled outline
/// by this much grows every edge outward by half of it, thickening the mark
/// uniformly.
///
/// Stated in pixels because the problem is a pixel problem: expressing it as a
/// fraction of the canvas is exactly what hides it.
func embolden(for pixelSize: CGFloat) -> CGFloat {
    switch pixelSize {
    case ..<24: 1.1
    case ..<48: 1.3
    case ..<96: 1.0
    case ..<192: 0.6
    default: 0
    }
}

// MARK: - Drawing

func markPath(scaledTo size: CGFloat) -> CGPath {
    let unit = size / MarkGeometry.canvas
    let path = CGMutablePath()
    // Design space runs top-left down; Core Graphics runs bottom-left up.
    for contour in MarkGeometry.contours {
        guard let first = contour.first else { continue }
        path.move(to: CGPoint(x: first.x * unit, y: size - first.y * unit))
        for point in contour.dropFirst() {
            path.addLine(to: CGPoint(x: point.x * unit, y: size - point.y * unit))
        }
        path.closeSubpath()
    }
    return path
}

func drawIcon(in context: CGContext, size: CGFloat) {
    // Ground: full bleed, near-white, with just enough gradient that it does
    // not read as a flat swatch.
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

    let path = markPath(scaledTo: size)

    context.setFillColor(ink)
    context.addPath(path)
    context.fillPath(using: .evenOdd)

    let extra = embolden(for: size)
    guard extra > 0 else { return }

    context.setStrokeColor(ink)
    context.setLineWidth(extra)
    context.setLineJoin(.round)
    context.setLineCap(.round)
    context.addPath(path)
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

@main
struct IconGenerator {
    static func main() throws {
        let arguments = CommandLine.arguments
        let outputDirectory = URL(
            filePath: arguments.count > 1
                ? arguments[1] : FileManager.default.currentDirectoryPath)
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

        // A standalone 1024pt PNG, for the README and anywhere else the mark is
        // needed.
        try renderPNG(size: 1024)
            .write(to: outputDirectory.appending(path: "Beckit-1024.png"))

        let iconutil = Process()
        iconutil.executableURL = URL(filePath: "/usr/bin/iconutil")
        iconutil.arguments = [
            "--convert", "icns",
            "--output",
            outputDirectory.appending(path: "Beckit.icns").path(percentEncoded: false),
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
    }
}
