#!/usr/bin/env swift
//
// Traces a reference PNG into vector contours and writes them out as Swift.
//
// This is a one-off tool, run by hand when the mark changes. Earlier attempts
// at the icon were drawn by eye from a thumbnail and were repeatedly not close
// enough; this reads the actual pixels instead.
//
// How it works:
//   1. Build a coverage field — how much ink each pixel holds, 0 to 1. The
//      source is antialiased, so this field is smooth and its half-way contour
//      lands between pixels rather than on them.
//   2. Marching squares at coverage 0.5, interpolating along each cell edge, so
//      the contour is sub-pixel accurate rather than stair-stepped.
//   3. Stitch the segments into closed loops.
//   4. Simplify with Douglas–Peucker, which removes the points that carry no
//      shape without moving the curve.
//   5. Normalise into a 1024-unit design space, centred.
//
// Output is filled contours with the even-odd rule, so the holes inside the
// mark come out as holes without any special handling.
//
// Usage: Scripts/trace-reference.swift <reference.png> <output.swift>

import AppKit
import CoreGraphics
import Foundation

let arguments = CommandLine.arguments
guard arguments.count == 3 else {
    FileHandle.standardError.write(Data(
        "usage: trace-reference.swift <reference.png> <output.swift>\n".utf8))
    exit(1)
}

// MARK: - Load

guard let source = NSImage(contentsOfFile: arguments[1]),
      let image = source.cgImage(forProposedRect: nil, context: nil, hints: nil)
else { fatalError("could not read \(arguments[1])") }

let width = image.width
let height = image.height

var pixels = [UInt8](repeating: 0, count: width * height * 4)
pixels.withUnsafeMutableBytes { buffer in
    guard let context = CGContext(
        data: buffer.baseAddress, width: width, height: height,
        bitsPerComponent: 8, bytesPerRow: width * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { fatalError("could not create a context") }
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
}

// MARK: - Coverage field

/// How much ink sits at each pixel, 0 (background) to 1 (solid).
///
/// Measured on the green channel, which separates this palette cleanly: the
/// pink ink is low in green and the near-white ground is high. Using luminance
/// would work too, but a single channel keeps the field monotonic and avoids
/// the halo that channel-mixing produces at antialiased edges.
///
/// The grid is padded by one cell of background on every side so that every
/// contour closes inside it and none run off an edge.
let padding = 2
let gridWidth = width + padding * 2
let gridHeight = height + padding * 2
var coverage = [Double](repeating: 0, count: gridWidth * gridHeight)

func pixel(_ x: Int, _ y: Int) -> (r: Double, g: Double, b: Double, a: Double) {
    let index = (y * width + x) * 4
    return (Double(pixels[index]) / 255, Double(pixels[index + 1]) / 255,
            Double(pixels[index + 2]) / 255, Double(pixels[index + 3]) / 255)
}

// Calibrate against the image itself rather than assuming the palette: the
// background is whatever sits in the corner, the ink is the greenest-poor pixel
// present.
let background = pixel(0, 0).g
var inkGreen = background
for y in 0..<height {
    for x in 0..<width where pixel(x, y).a > 0.5 {
        inkGreen = min(inkGreen, pixel(x, y).g)
    }
}
let range = max(background - inkGreen, 0.001)

for y in 0..<height {
    for x in 0..<width {
        let sample = pixel(x, y)
        // Treat transparency as background, so a PNG with an alpha channel and
        // one with a baked-in white ground trace identically.
        let green = sample.a < 0.5 ? background : sample.g
        let value = min(max((background - green) / range, 0), 1)
        coverage[(y + padding) * gridWidth + (x + padding)] = value
    }
}

func value(_ x: Int, _ y: Int) -> Double { coverage[y * gridWidth + x] }

// MARK: - Marching squares

struct Point: Hashable {
    var x: Double
    var y: Double

    /// Quantised key, for stitching segments whose shared endpoint was computed
    /// twice and may differ in the last bits.
    var key: Int64 {
        Int64((x * 4096).rounded()) &* 1_000_003 &+ Int64((y * 4096).rounded())
    }
}

let threshold = 0.5

/// Where the contour crosses between two samples.
func crossing(
    _ ax: Double, _ ay: Double, _ av: Double,
    _ bx: Double, _ by: Double, _ bv: Double
) -> Point {
    let t = (threshold - av) / (bv - av)
    let clamped = min(max(t, 0), 1)
    return Point(x: ax + (bx - ax) * clamped, y: ay + (by - ay) * clamped)
}

var segments: [(Point, Point)] = []

for y in 0..<(gridHeight - 1) {
    for x in 0..<(gridWidth - 1) {
        let a = value(x, y)          // top left
        let b = value(x + 1, y)      // top right
        let c = value(x + 1, y + 1)  // bottom right
        let d = value(x, y + 1)      // bottom left

        var code = 0
        if a > threshold { code |= 1 }
        if b > threshold { code |= 2 }
        if c > threshold { code |= 4 }
        if d > threshold { code |= 8 }
        if code == 0 || code == 15 { continue }

        let fx = Double(x), fy = Double(y)
        let top = crossing(fx, fy, a, fx + 1, fy, b)
        let right = crossing(fx + 1, fy, b, fx + 1, fy + 1, c)
        let bottom = crossing(fx, fy + 1, d, fx + 1, fy + 1, c)
        let left = crossing(fx, fy, a, fx, fy + 1, d)

        // Segments are emitted with the interior on a consistent side, so the
        // stitched loops all wind the same way.
        switch code {
        case 1: segments.append((left, top))
        case 2: segments.append((top, right))
        case 3: segments.append((left, right))
        case 4: segments.append((right, bottom))
        case 6: segments.append((top, bottom))
        case 7: segments.append((left, bottom))
        case 8: segments.append((bottom, left))
        case 9: segments.append((bottom, top))
        case 11: segments.append((bottom, right))
        case 12: segments.append((right, left))
        case 13: segments.append((right, top))
        case 14: segments.append((top, left))
        case 5, 10:
            // Saddle: the cell's centre decides which way the two strands pass.
            let centre = (a + b + c + d) / 4
            if (code == 5) == (centre > threshold) {
                segments.append((left, top))
                segments.append((right, bottom))
            } else {
                segments.append((left, bottom))
                segments.append((right, top))
            }
        default: break
        }
    }
}

// MARK: - Stitch into loops

var outgoing: [Int64: [Int]] = [:]
for (index, segment) in segments.enumerated() {
    outgoing[segment.0.key, default: []].append(index)
}

var used = [Bool](repeating: false, count: segments.count)
var loops: [[Point]] = []

for start in segments.indices where !used[start] {
    var loop: [Point] = [segments[start].0]
    var current = start
    used[current] = true

    while true {
        let end = segments[current].1
        loop.append(end)

        guard let candidates = outgoing[end.key],
              let next = candidates.first(where: { !used[$0] })
        else { break }

        used[next] = true
        current = next
    }

    // A contour worth keeping encloses actual area; stray two-segment scraps at
    // antialiasing edges do not.
    if loop.count > 8 { loops.append(loop) }
}

// MARK: - Simplify

/// Douglas–Peucker: drop every point that sits within `tolerance` of the line
/// between the points that survive. Removes the run-length of near-collinear
/// samples marching squares produces without moving the curve.
func simplify(_ points: [Point], tolerance: Double) -> [Point] {
    guard points.count > 3 else { return points }

    func perpendicularDistance(_ p: Point, _ a: Point, _ b: Point) -> Double {
        let dx = b.x - a.x, dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else { return hypot(p.x - a.x, p.y - a.y) }
        let t = ((p.x - a.x) * dx + (p.y - a.y) * dy) / lengthSquared
        let clamped = min(max(t, 0), 1)
        return hypot(p.x - (a.x + clamped * dx), p.y - (a.y + clamped * dy))
    }

    var keep = [Bool](repeating: false, count: points.count)
    keep[0] = true
    keep[points.count - 1] = true

    var stack = [(0, points.count - 1)]
    while let (first, last) = stack.popLast() {
        guard last > first + 1 else { continue }
        var worst = 0.0
        var worstIndex = first
        for index in (first + 1)..<last {
            let distance = perpendicularDistance(points[index], points[first], points[last])
            if distance > worst { worst = distance; worstIndex = index }
        }
        if worst > tolerance {
            keep[worstIndex] = true
            stack.append((first, worstIndex))
            stack.append((worstIndex, last))
        }
    }

    return points.indices.filter { keep[$0] }.map { points[$0] }
}

// A fifth of a source pixel. At the ~6x the icon is rendered to, that is about
// one pixel of deviation — under what antialiasing already blurs.
let simplified = loops.map { simplify($0, tolerance: 0.2) }

// MARK: - Normalise

var minX = Double.greatestFiniteMagnitude, minY = Double.greatestFiniteMagnitude
var maxX = -Double.greatestFiniteMagnitude, maxY = -Double.greatestFiniteMagnitude
for loop in simplified {
    for point in loop {
        minX = min(minX, point.x); maxX = max(maxX, point.x)
        minY = min(minY, point.y); maxY = max(maxY, point.y)
    }
}

// Fit the traced ink into a 1024 design space at the share of the tile macOS 26
// leaves for artwork once its icon mask is applied, and centre it.
let canvas = 1024.0
let coverageFraction = 0.66
let scale = canvas * coverageFraction / max(maxX - minX, maxY - minY)
let offsetX = (canvas - (maxX - minX) * scale) / 2 - minX * scale
let offsetY = (canvas - (maxY - minY) * scale) / 2 - minY * scale

// MARK: - Emit

var output = """
// Generated by Scripts/trace-reference.swift — do not edit by hand.
//
// Contours traced from the reference artwork, in a 1024-unit design space with
// the origin at the top left. Fill with the even-odd rule: the mark's holes are
// contours in their own right and even-odd turns them into holes without any
// special handling.
//
// Shared by the icon generator and the in-app mark so the two cannot drift.

import CoreGraphics

public enum MarkGeometry {
    public static let canvas: CGFloat = 1024

    public static let contours: [[CGPoint]] = [\n
"""

for loop in simplified {
    output += "        [\n"
    for (index, point) in loop.enumerated() {
        let x = point.x * scale + offsetX
        let y = point.y * scale + offsetY
        output += String(format: "            CGPoint(x: %.2f, y: %.2f),", x, y)
        output += (index % 3 == 2) ? "\n" : ""
    }
    if !output.hasSuffix("\n") { output += "\n" }
    output += "        ],\n"
}

output += """
    ]
}

"""

try output.write(toFile: arguments[2], atomically: true, encoding: .utf8)

let totalPoints = simplified.reduce(0) { $0 + $1.count }
print("traced \(simplified.count) contours, \(totalPoints) points → \(arguments[2])")
