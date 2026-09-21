import AppKit
import Foundation

// Ask the system for the app's icon the same way Finder does, then confirm it
// matches the artwork we shipped rather than a generic placeholder.
@main struct R {
    static func main() {
        let appPath = CommandLine.arguments[1]
        let icon = NSWorkspace.shared.icon(forFile: appPath)

        print("System reports icon size: \(Int(icon.size.width))×\(Int(icon.size.height))")
        print("Representations: \(icon.representations.count)")

        // Rasterise the largest representation and check its dominant colour.
        // Render into a known bitmap: NSWorkspace's image is a composite whose
        // representations are not always NSBitmapImageRep.
        let side = 256
        guard let ctx = CGContext(data: nil, width: side, height: side,
                                  bitsPerComponent: 8, bytesPerRow: side * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { print("✗ Could not create the canvas"); exit(1) }
        ctx.draw(icon.cgImage(forProposedRect: nil, context: nil, hints: nil)!,
                 in: CGRect(x: 0, y: 0, width: side, height: side))
        guard let bmp = ctx.makeImage() else { print("✗ Render failed"); exit(1) }
        print("Rendered size: \(bmp.width)×\(bmp.height)")

        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        pixels.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress,
                  let c = CGContext(data: base, width: side, height: side,
                                    bitsPerComponent: 8, bytesPerRow: side * 4,
                                    space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return }
            c.draw(bmp, in: CGRect(x: 0, y: 0, width: side, height: side))
        }

        var hist: [Int: Int] = [:]
        var opaque = 0
        for y in stride(from: 0, to: side, by: 2) {
            for x in stride(from: 0, to: side, by: 2) {
                let i = (y * side + x) * 4
                let c = (r: pixels[i], g: pixels[i+1], b: pixels[i+2], a: pixels[i+3])
                guard c.a > 200 else { continue }
                opaque += 1
                hist[(Int(c.r) >> 4) << 8 | (Int(c.g) >> 4) << 4 | (Int(c.b) >> 4), default: 0] += 1
            }
        }
        let top = hist.sorted { $0.value > $1.value }.prefix(4)
        print("Dominant colours:")
        var dominantBlue = false
        for (k, v) in top {
            let r = ((k >> 8) & 15) * 17, g = ((k >> 4) & 15) * 17, b = (k & 15) * 17
            print(String(format: "  #%02X%02X%02X  %d", r, g, b, v))
            if b > 60 && b > r + 30 && b > g + 30 { dominantBlue = true }
        }

        // The artwork is deep blue; a generic app icon would not be.
        let hasContent = opaque > 100 && hist.count > 5
        print()
        print(hasContent ? "✓ Icon contains real image content" : "✗ Icon is empty or a placeholder")
        print(dominantBlue ? "✓ Dominant colour is blue, matching the artwork" : "? Dominant colour is not blue; please check")
        exit(hasContent && dominantBlue ? 0 : 1)
    }
}
