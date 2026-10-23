// Gallery pixel diff (spec C §8). Compiled once by scripts/gallery.py, then fed pairs on stdin:
//   <base.png>\t<current.png>\t<diff.png or ->\t<tolerance>
// For each pair it prints one JSON line: changed pixels, share, bounding box, size change, largest channel delta.
// Both images are decoded into the same 8-bit sRGB RGBA buffer, so the comparison is exact (tolerance 0 by default).
// The diff image shows the base in light grey and every changed pixel in magenta.
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct Pixels {
    let width: Int
    let height: Int
    var bytes: [UInt8]
}

func load(_ path: String) -> Pixels? {
    guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
    let width = image.width, height = image.height
    var bytes = [UInt8](repeating: 0, count: width * height * 4)
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
        guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return true
    }
    return drawn ? Pixels(width: width, height: height, bytes: bytes) : nil
}

func writePNG(_ pixels: Pixels, to path: String) -> Bool {
    var bytes = pixels.bytes
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    return bytes.withUnsafeMutableBytes { buffer -> Bool in
        guard let context = CGContext(data: buffer.baseAddress, width: pixels.width, height: pixels.height,
                                      bitsPerComponent: 8, bytesPerRow: pixels.width * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let image = context.makeImage() else { return false }
        let url = URL(fileURLWithPath: path)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).tmp")
        guard let destination = CGImageDestinationCreateWithURL(temporary as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { return false }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return false }
        return rename(temporary.path, url.path) == 0
    }
}

func compare(base basePath: String, current currentPath: String, diffPath: String?, tolerance: Int) -> [String: Any] {
    guard let base = load(basePath) else { return ["error": "base unreadable: \(basePath)"] }
    guard let current = load(currentPath) else { return ["error": "current unreadable: \(currentPath)"] }
    if base.width != current.width || base.height != current.height {
        return ["sizeChanged": true, "baseSize": [base.width, base.height], "currentSize": [current.width, current.height],
                "changed": max(base.width * base.height, current.width * current.height),
                "total": current.width * current.height, "percent": 100.0]
    }
    let width = base.width, height = base.height
    var changed = 0, maxDelta = 0
    var minX = width, minY = height, maxX = -1, maxY = -1
    var diff = Pixels(width: width, height: height, bytes: [UInt8](repeating: 0, count: width * height * 4))
    base.bytes.withUnsafeBufferPointer { a in
        current.bytes.withUnsafeBufferPointer { b in
            diff.bytes.withUnsafeMutableBufferPointer { d in
                for y in 0..<height {
                    for x in 0..<width {
                        let i = (y * width + x) * 4
                        var delta = 0
                        for c in 0..<4 { delta = max(delta, abs(Int(a[i + c]) - Int(b[i + c]))) }
                        maxDelta = max(maxDelta, delta)
                        if delta > tolerance {
                            changed += 1
                            minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
                            d[i] = 255; d[i + 1] = 0; d[i + 2] = 255; d[i + 3] = 255
                        } else {
                            let luma = (Int(a[i]) * 3 + Int(a[i + 1]) * 6 + Int(a[i + 2])) / 10
                            let grey = UInt8(170 + luma * 70 / 255)
                            d[i] = grey; d[i + 1] = grey; d[i + 2] = grey; d[i + 3] = 255
                        }
                    }
                }
            }
        }
    }
    var result: [String: Any] = ["sizeChanged": false, "changed": changed, "total": width * height,
                                 "percent": Double(changed) * 100 / Double(max(1, width * height)), "maxDelta": maxDelta]
    if changed > 0 {
        // Top-left origin, in pixels, as a person reads the PNG.
        result["bbox"] = [minX, minY, maxX - minX + 1, maxY - minY + 1]
        if let diffPath, diffPath != "-" { result["diff"] = writePNG(diff, to: diffPath) ? diffPath : "" }
    }
    return result
}

while let line = readLine(strippingNewline: true) {
    let parts = line.components(separatedBy: "\t")
    guard parts.count >= 2 else { continue }
    let tolerance = parts.count > 3 ? Int(parts[3]) ?? 0 : 0
    var result = compare(base: parts[0], current: parts[1], diffPath: parts.count > 2 ? parts[2] : nil, tolerance: tolerance)
    result["base"] = parts[0]; result["current"] = parts[1]
    let data = (try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])) ?? Data("{}".utf8)
    FileHandle.standardOutput.write(data + Data("\n".utf8))
}
