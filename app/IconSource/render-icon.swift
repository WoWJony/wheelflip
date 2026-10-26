import AppKit
import Foundation

// Run from any directory: swift app/IconSource/render-icon.swift
// AppKit renders the editable SVG without third-party dependencies.
let sourceDirectory = URL(fileURLWithPath: #filePath).standardizedFileURL.deletingLastPathComponent()
let appDirectory = sourceDirectory.deletingLastPathComponent()
let repositoryDirectory = appDirectory.deletingLastPathComponent()
let outputDirectory = repositoryDirectory.appendingPathComponent("output/wheelflip-icon")
let assetDirectory = appDirectory.appendingPathComponent("WheelFlip/Resources/Assets.xcassets/AppIconV2.appiconset")
let iconsetDirectory = outputDirectory.appendingPathComponent("WheelFlip.iconset")
let manager = FileManager.default
let source = try String(contentsOf: sourceDirectory.appendingPathComponent("wheelflip-icon-v2.svg"), encoding: .utf8)

for directory in [outputDirectory, assetDirectory, iconsetDirectory] {
    try manager.createDirectory(at: directory, withIntermediateDirectories: true)
}

func rasterize(_ svg: String, width: Int, height: Int) throws -> Data {
    guard let image = NSImage(data: Data(svg.utf8)), image.isValid,
          let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
          ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
        throw NSError(domain: "WheelFlipIcon", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not create SVG rendering context"])
    }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.imageInterpolation = .high
    image.draw(in: NSRect(x: 0, y: 0, width: width, height: height), from: .zero, operation: .copy, fraction: 1)
    context.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()
    guard let data = bitmap.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "WheelFlipIcon", code: 2, userInfo: [NSLocalizedDescriptionKey: "Could not encode PNG"])
    }
    return data
}

func artwork(at pixels: Int) -> String {
    guard pixels <= 32,
          let start = source.range(of: "<!-- wheel-detail:start -->"),
          let end = source.range(of: "<!-- wheel-detail:end -->") else { return source }
    // One open groove survives small-size sampling better than three fine treads.
    let slot = "<rect x=\"494\" y=\"401\" width=\"36\" height=\"18\" rx=\"9\" fill=\"#a8b0a9\"/>"
    return source.replacingCharacters(in: start.lowerBound..<end.upperBound, with: slot)
}

var images: [[String: String]] = []
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let filename = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
        let data = try rasterize(artwork(at: pixels), width: pixels, height: pixels)
        try data.write(to: assetDirectory.appendingPathComponent(filename))
        try data.write(to: iconsetDirectory.appendingPathComponent(filename))
        images.append(["filename": filename, "idiom": "mac", "scale": "\(scale)x", "size": "\(size)x\(size)"])
    }
}
let catalog: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
let contents = try JSONSerialization.data(withJSONObject: catalog, options: [.prettyPrinted, .sortedKeys])
try contents.write(to: assetDirectory.appendingPathComponent("Contents.json"))
try rasterize(source, width: 1024, height: 1024).write(to: outputDirectory.appendingPathComponent("wheelflip-icon-1024.png"))

// A compact light/dark proof sheet, with actual-size samples along the bottom.
func embeddedIcon(x: Int, y: Int, size: Int) -> String {
    artwork(at: size).replacingOccurrences(
        of: "width=\"1024\" height=\"1024\" viewBox=\"0 0 1024 1024\"",
        with: "x=\"\(x)\" y=\"\(y)\" width=\"\(size)\" height=\"\(size)\" viewBox=\"0 0 1024 1024\""
    )
}
let proof = """
<svg xmlns="http://www.w3.org/2000/svg" width="1200" height="860" viewBox="0 0 1200 860">
  <rect width="1200" height="860" fill="#eeefea"/>
  <rect x="720" width="480" height="640" fill="#202622"/>
  <text x="64" y="74" font-family="Helvetica Neue,Helvetica,sans-serif" font-size="28" font-weight="500" fill="#29332c">WheelFlip</text>
  <text x="65" y="105" font-family="Helvetica Neue,Helvetica,sans-serif" font-size="14" fill="#68736a">LADYBIRD / PORCELAIN</text>
  \(embeddedIcon(x: 106, y: 127, size: 512))
  \(embeddedIcon(x: 810, y: 176, size: 300))
  <text x="960" y="534" font-family="Helvetica Neue,Helvetica,sans-serif" font-size="14" text-anchor="middle" fill="#b9c2ba">Dark background</text>
  <path d="M64 665 H1136" stroke="#cdd3cb"/>
  <text x="64" y="710" font-family="Helvetica Neue,Helvetica,sans-serif" font-size="14" fill="#68736a">ACTUAL SIZE</text>
  \(embeddedIcon(x: 265, y: 740, size: 16))
  \(embeddedIcon(x: 397, y: 732, size: 32))
  \(embeddedIcon(x: 550, y: 716, size: 64))
  \(embeddedIcon(x: 746, y: 684, size: 128))
  <g font-family="Helvetica Neue,Helvetica,sans-serif" font-size="13" text-anchor="middle" fill="#68736a">
    <text x="273" y="827">16</text><text x="413" y="827">32</text>
    <text x="582" y="827">64</text><text x="810" y="827">128 px</text>
  </g>
</svg>
"""
try rasterize(proof, width: 1200, height: 860).write(to: outputDirectory.appendingPathComponent("preview.png"))

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconsetDirectory.path, "-o", outputDirectory.appendingPathComponent("WheelFlip.icns").path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else {
    throw NSError(domain: "WheelFlipIcon", code: 3, userInfo: [NSLocalizedDescriptionKey: "iconutil could not package the ICNS file"])
}
print("Rendered AppIconV2 (10 PNGs), 1024 px master, ICNS, and light/dark proof sheet.")
