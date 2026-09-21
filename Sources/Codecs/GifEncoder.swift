import Foundation
import CoreGraphics

// MARK: - Colour quantisation

/// Median-cut quantiser over a 15-bit RGB histogram. Fast, deterministic and
/// good enough for photographic GIF content.
struct ColorQuantizer {

    struct Palette {
        var red: [UInt8]
        var green: [UInt8]
        var blue: [UInt8]
        var count: Int

        /// Nearest-palette-colour lookup table indexed by 15-bit RGB.
        /// 32768 entries keeps mapping O(1) per pixel.
        func lookupTable() -> [UInt8] {
            var table = [UInt8](repeating: 0, count: 32768)
            for r in 0..<32 {
                for g in 0..<32 {
                    for b in 0..<32 {
                        let index = (r << 10) | (g << 5) | b
                        var best = 0
                        var bestDistance = Int.max
                        // Expand 5-bit to 8-bit for a fair distance metric.
                        let rr = r << 3, gg = g << 3, bb = b << 3
                        for i in 0..<count {
                            let dr = Int(red[i]) - rr
                            let dg = Int(green[i]) - gg
                            let db = Int(blue[i]) - bb
                            let distance = dr * dr + dg * dg + db * db
                            if distance < bestDistance {
                                bestDistance = distance
                                best = i
                            }
                        }
                        table[index] = UInt8(best)
                    }
                }
            }
            return table
        }
    }

    private struct Bucket {
        var bins: [Int]      // indices into the histogram
        var rMin: Int, rMax: Int
        var gMin: Int, gMax: Int
        var bMin: Int, bMax: Int

        var volume: Int {
            (rMax - rMin + 1) * (gMax - gMin + 1) * (bMax - bMin + 1)
        }
    }

    /// Build a palette from sampled RGBA pixels.
    /// - Parameters:
    ///   - pixels: interleaved RGBA8 data.
    ///   - sampleStride: take every Nth pixel; 1 uses all pixels.
    static func quantize(pixels: [UInt8], colorCount: Int, sampleStride: Int = 3) -> Palette {
        var histogram = [Int](repeating: 0, count: 32768)
        let pixelCount = pixels.count / 4
        var index = 0
        while index < pixelCount {
            let offset = index * 4
            let r = Int(pixels[offset]) >> 3
            let g = Int(pixels[offset + 1]) >> 3
            let b = Int(pixels[offset + 2]) >> 3
            histogram[(r << 10) | (g << 5) | b] += 1
            index += max(sampleStride, 1)
        }
        return quantize(histogram: histogram, colorCount: colorCount)
    }

    static func quantize(histogram: [Int], colorCount: Int) -> Palette {
        var populated: [Int] = []
        populated.reserveCapacity(4096)
        for i in 0..<32768 where histogram[i] > 0 { populated.append(i) }

        guard !populated.isEmpty else {
            // Degenerate input: return a black palette.
            return Palette(red: [0], green: [0], blue: [0], count: 1)
        }

        var buckets: [Bucket] = [makeBucket(populated)]

        // Split the widest bucket until we reach the requested colour count.
        while buckets.count < colorCount {
            guard let splitIndex = buckets.indices
                .filter({ buckets[$0].bins.count > 1 })
                .max(by: { buckets[$0].volume * buckets[$0].bins.count
                        < buckets[$1].volume * buckets[$1].bins.count })
            else { break }

            let bucket = buckets[splitIndex]
            let (left, right) = split(bucket, histogram: histogram)
            guard !left.bins.isEmpty, !right.bins.isEmpty else {
                // Cannot split further; mark it exhausted by shrinking the range.
                buckets[splitIndex].rMin = buckets[splitIndex].rMax
                buckets[splitIndex].gMin = buckets[splitIndex].gMax
                buckets[splitIndex].bMin = buckets[splitIndex].bMax
                if buckets.allSatisfy({ $0.bins.count <= 1 }) { break }
                continue
            }
            buckets[splitIndex] = left
            buckets.append(right)
        }

        var reds: [UInt8] = [], greens: [UInt8] = [], blues: [UInt8] = []
        reds.reserveCapacity(buckets.count)
        greens.reserveCapacity(buckets.count)
        blues.reserveCapacity(buckets.count)

        for bucket in buckets {
            var sumR = 0, sumG = 0, sumB = 0, total = 0
            for bin in bucket.bins {
                let weight = histogram[bin]
                sumR += ((bin >> 10) & 31) << 3
                sumG += ((bin >> 5) & 31) << 3
                sumB += (bin & 31) << 3
                total += weight
            }
            guard total > 0 else {
                reds.append(0); greens.append(0); blues.append(0)
                continue
            }
            // Weighted average, weighted by how often each bin occurs.
            var weightR = 0, weightG = 0, weightB = 0
            for bin in bucket.bins {
                let weight = histogram[bin]
                weightR += (((bin >> 10) & 31) << 3) * weight
                weightG += (((bin >> 5) & 31) << 3) * weight
                weightB += ((bin & 31) << 3) * weight
            }
            reds.append(UInt8(min(weightR / total, 255)))
            greens.append(UInt8(min(weightG / total, 255)))
            blues.append(UInt8(min(weightB / total, 255)))
            _ = (sumR, sumG, sumB)
        }

        return Palette(red: reds, green: greens, blue: blues, count: reds.count)
    }

    private static func makeBucket(_ bins: [Int]) -> Bucket {
        var rMin = 31, rMax = 0, gMin = 31, gMax = 0, bMin = 31, bMax = 0
        for bin in bins {
            let r = (bin >> 10) & 31, g = (bin >> 5) & 31, b = bin & 31
            rMin = min(rMin, r); rMax = max(rMax, r)
            gMin = min(gMin, g); gMax = max(gMax, g)
            bMin = min(bMin, b); bMax = max(bMax, b)
        }
        return Bucket(bins: bins, rMin: rMin, rMax: rMax, gMin: gMin, gMax: gMax, bMin: bMin, bMax: bMax)
    }

    private static func split(_ bucket: Bucket, histogram: [Int]) -> (Bucket, Bucket) {
        let rRange = bucket.rMax - bucket.rMin
        let gRange = bucket.gMax - bucket.gMin
        let bRange = bucket.bMax - bucket.bMin

        let axis: Int = (rRange >= gRange && rRange >= bRange) ? 0 : (gRange >= bRange ? 1 : 2)
        let sorted = bucket.bins.sorted { a, b in
            switch axis {
            case 0: return ((a >> 10) & 31) < ((b >> 10) & 31)
            case 1: return ((a >> 5) & 31) < ((b >> 5) & 31)
            default: return (a & 31) < (b & 31)
            }
        }

        // Split at the weighted median so both halves carry similar pixel mass.
        let total = sorted.reduce(0) { $0 + histogram[$1] }
        var running = 0
        var splitPoint = sorted.count / 2
        for (i, bin) in sorted.enumerated() {
            running += histogram[bin]
            if running * 2 >= total { splitPoint = i + 1; break }
        }
        splitPoint = min(max(splitPoint, 1), sorted.count - 1)

        let left = Array(sorted[..<splitPoint])
        let right = Array(sorted[splitPoint...])
        return (makeBucket(left), makeBucket(right))
    }
}

// MARK: - LZW

/// GIF-flavoured LZW with LSB-first bit packing.
final class LzwEncoder {
    private var output: [UInt8] = []
    private var current: UInt32 = 0
    private var bitCount = 0

    func encode(indices: [UInt8], minCodeSize: Int) -> [UInt8] {
        output.removeAll(keepingCapacity: true)
        current = 0
        bitCount = 0

        let clearCode = 1 << minCodeSize
        let endCode = clearCode + 1
        var codeSize = minCodeSize + 1
        var nextCode = endCode + 1

        var dictionary: [Int: Int] = [:]
        dictionary.reserveCapacity(4096)

        write(clearCode, bits: codeSize)

        guard !indices.isEmpty else {
            write(endCode, bits: codeSize)
            flush()
            return output
        }

        var prefix = Int(indices[0])
        for i in 1..<indices.count {
            let pixel = Int(indices[i])
            let key = (prefix << 8) | pixel
            if let code = dictionary[key] {
                prefix = code
            } else {
                write(prefix, bits: codeSize)
                if nextCode < 4096 {
                    dictionary[key] = nextCode
                    nextCode += 1
                    // Grow the code width only after the table crosses a power of two.
                    if nextCode > (1 << codeSize), codeSize < 12 {
                        codeSize += 1
                    }
                } else {
                    write(clearCode, bits: codeSize)
                    dictionary.removeAll(keepingCapacity: true)
                    codeSize = minCodeSize + 1
                    nextCode = endCode + 1
                }
                prefix = pixel
            }
        }

        write(prefix, bits: codeSize)
        write(endCode, bits: codeSize)
        flush()
        return output
    }

    private func write(_ code: Int, bits: Int) {
        current |= UInt32(code) << UInt32(bitCount)
        bitCount += bits
        while bitCount >= 8 {
            output.append(UInt8(current & 0xFF))
            current >>= 8
            bitCount -= 8
        }
    }

    private func flush() {
        if bitCount > 0 {
            output.append(UInt8(current & 0xFF))
            current = 0
            bitCount = 0
        }
    }
}

// MARK: - GIF writer

/// Streaming GIF89a writer with a global colour table.
final class GifWriter {
    private let handle: FileHandle
    private let palette: ColorQuantizer.Palette
    private let lookup: [UInt8]
    private let width: Int
    private let height: Int
    private let minCodeSize: Int
    private let encoder = LzwEncoder()

    init(url: URL, width: Int, height: Int, palette: ColorQuantizer.Palette, loopCount: Int) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: url) else {
            throw ProcessError.failed(code: 0, message: L("ui.could_not_create_the_gif_file"))
        }
        self.handle = handle
        self.palette = palette
        self.width = width
        self.height = height
        self.lookup = palette.lookupTable()

        // GIF requires a minimum code size of at least 2.
        let bits = max(2, Int(ceil(log2(Double(max(palette.count, 2))))))
        self.minCodeSize = bits

        writeHeader(loopCount: loopCount)
    }

    private func writeHeader(loopCount: Int) {
        var bytes: [UInt8] = []
        bytes += Array("GIF89a".utf8)

        // Logical screen descriptor.
        bytes += littleEndian16(width)
        bytes += littleEndian16(height)
        // Global colour table present, colour resolution 8, table size bits.
        let tableSizeBits = minCodeSize - 1
        bytes.append(0xF0 | UInt8(tableSizeBits))
        bytes.append(0)   // background colour index
        bytes.append(0)   // pixel aspect ratio

        // Global colour table, padded to a power of two.
        let tableEntries = 1 << minCodeSize
        for i in 0..<tableEntries {
            if i < palette.count {
                bytes.append(palette.red[i])
                bytes.append(palette.green[i])
                bytes.append(palette.blue[i])
            } else {
                bytes += [0, 0, 0]
            }
        }

        // Netscape looping extension.
        bytes += [0x21, 0xFF, 0x0B]
        bytes += Array("NETSCAPE2.0".utf8)
        bytes += [0x03, 0x01]
        bytes += littleEndian16(loopCount)
        bytes.append(0x00)

        handle.write(Data(bytes))
    }

    /// 4×4 Bayer threshold matrix, normalised to -0.5…0.5.
    private static let bayerMatrix: [Double] = [
        0, 8, 2, 10,
        12, 4, 14, 6,
        3, 11, 1, 9,
        15, 7, 13, 5,
    ].map { Double($0) / 16.0 - 0.5 }

    /// Append one frame. `pixels` is RGBA8 of exactly `width * height`.
    /// When `dither` is set, an ordered Bayer offset is applied before the
    /// palette lookup, which breaks up banding in smooth gradients.
    func addFrame(pixels: [UInt8], delayCentiseconds: Int, disposal: Int = 2,
                  dither: Bool = false) {
        var indices = [UInt8](repeating: 0, count: width * height)
        // 5-bit quantisation step, matching the lookup table's resolution.
        let amplitude = 8.0

        var y = 0
        while y < height {
            var x = 0
            while x < width {
                let index = y * width + x
                let p = index * 4

                var r = Int(pixels[p])
                var g = Int(pixels[p + 1])
                var b = Int(pixels[p + 2])

                if dither {
                    let threshold = Self.bayerMatrix[(y & 3) * 4 + (x & 3)] * amplitude
                    r = Self.clamp(r + Int(threshold))
                    g = Self.clamp(g + Int(threshold))
                    b = Self.clamp(b + Int(threshold))
                }

                indices[index] = lookup[((r >> 3) << 10) | ((g >> 3) << 5) | (b >> 3)]
                x += 1
            }
            y += 1
        }
        addFrame(indices: indices, delayCentiseconds: delayCentiseconds, disposal: disposal)
    }

    private static func clamp(_ value: Int) -> Int { min(max(value, 0), 255) }

    func addFrame(indices: [UInt8], delayCentiseconds: Int, disposal: Int = 2) {
        var bytes: [UInt8] = []

        // Graphic control extension.
        bytes += [0x21, 0xF9, 0x04]
        bytes.append(UInt8((disposal & 0x07) << 2))
        bytes += littleEndian16(max(delayCentiseconds, 1))
        bytes.append(0)   // transparent colour index (unused)
        bytes.append(0)

        // Image descriptor.
        bytes.append(0x2C)
        bytes += littleEndian16(0)
        bytes += littleEndian16(0)
        bytes += littleEndian16(width)
        bytes += littleEndian16(height)
        bytes.append(0)   // no local colour table, not interlaced

        bytes.append(UInt8(minCodeSize))

        // LZW data, split into sub-blocks of at most 255 bytes.
        let compressed = encoder.encode(indices: indices, minCodeSize: minCodeSize)
        var offset = 0
        while offset < compressed.count {
            let chunk = min(255, compressed.count - offset)
            bytes.append(UInt8(chunk))
            bytes.append(contentsOf: compressed[offset..<(offset + chunk)])
            offset += chunk
        }
        bytes.append(0)   // block terminator

        handle.write(Data(bytes))
    }

    func finish() {
        handle.write(Data([0x3B]))
        try? handle.close()
    }

    private func littleEndian16(_ value: Int) -> [UInt8] {
        [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF)]
    }
}

// MARK: - Pixel canvas

/// Simple RGBA8 canvas used to compose GIF frames and transitions.
struct PixelCanvas {
    let width: Int
    let height: Int
    var pixels: [UInt8]

    init(width: Int, height: Int, background: (UInt8, UInt8, UInt8) = (0, 0, 0)) {
        self.width = max(width, 1)
        self.height = max(height, 1)
        self.pixels = [UInt8](repeating: 0, count: self.width * self.height * 4)
        fill(background)
    }

    mutating func fill(_ color: (UInt8, UInt8, UInt8)) {
        var i = 0
        while i < pixels.count {
            pixels[i] = color.0
            pixels[i + 1] = color.1
            pixels[i + 2] = color.2
            pixels[i + 3] = 255
            i += 4
        }
    }

    /// Render a CGImage into the canvas using the given fit mode.
    static func render(
        image: CGImage, width: Int, height: Int,
        fit: ImageFit, background: (UInt8, UInt8, UInt8)
    ) -> PixelCanvas {
        var canvas = PixelCanvas(width: width, height: height, background: background)
        guard let resized = ImageSupport.resize(
            image, to: CGSize(width: width, height: height),
            fit: fit == .stretch ? .stretch : fit,
            background: CGColor(red: CGFloat(background.0) / 255,
                                green: CGFloat(background.1) / 255,
                                blue: CGFloat(background.2) / 255, alpha: 1)
        ) else { return canvas }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        canvas.pixels.withUnsafeMutableBytes { buffer in
            guard let base = buffer.baseAddress,
                  let context = CGContext(
                    data: base, width: width, height: height,
                    bitsPerComponent: 8, bytesPerRow: width * 4, space: colorSpace,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return }
            context.interpolationQuality = .high
            context.draw(resized, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return canvas
    }

    /// Alpha-blend another canvas over this one. `amount` is 0…1.
    func blended(with other: PixelCanvas, amount: Double) -> PixelCanvas {
        var result = self
        let t = min(max(amount, 0), 1)
        let inverse = 1 - t
        let count = min(pixels.count, other.pixels.count)
        for i in stride(from: 0, to: count, by: 4) {
            result.pixels[i] = UInt8(Double(pixels[i]) * inverse + Double(other.pixels[i]) * t)
            result.pixels[i + 1] = UInt8(Double(pixels[i + 1]) * inverse + Double(other.pixels[i + 1]) * t)
            result.pixels[i + 2] = UInt8(Double(pixels[i + 2]) * inverse + Double(other.pixels[i + 2]) * t)
            result.pixels[i + 3] = 255
        }
        return result
    }

    /// Horizontal slide: `other` enters from the given direction.
    func slid(with other: PixelCanvas, progress: Double, fromLeft: Bool) -> PixelCanvas {
        var result = self
        let offset = Int(Double(width) * min(max(progress, 0), 1))
        for y in 0..<height {
            for x in 0..<width {
                let sourceX = fromLeft ? x + (width - offset) : x - offset
                let index = (y * width + x) * 4
                if sourceX >= 0 && sourceX < width {
                    let sourceIndex = (y * width + sourceX) * 4
                    result.pixels[index] = other.pixels[sourceIndex]
                    result.pixels[index + 1] = other.pixels[sourceIndex + 1]
                    result.pixels[index + 2] = other.pixels[sourceIndex + 2]
                } else {
                    result.pixels[index] = pixels[index]
                    result.pixels[index + 1] = pixels[index + 1]
                    result.pixels[index + 2] = pixels[index + 2]
                }
                result.pixels[index + 3] = 255
            }
        }
        return result
    }

    /// Wipe: `other` is revealed progressively from one edge.
    func wiped(with other: PixelCanvas, progress: Double, fromLeft: Bool) -> PixelCanvas {
        var result = self
        let edge = Int(Double(width) * min(max(progress, 0), 1))
        for y in 0..<height {
            for x in 0..<width {
                let reveal = fromLeft ? x < edge : x >= width - edge
                let index = (y * width + x) * 4
                let source = reveal ? other.pixels : pixels
                result.pixels[index] = source[index]
                result.pixels[index + 1] = source[index + 1]
                result.pixels[index + 2] = source[index + 2]
                result.pixels[index + 3] = 255
            }
        }
        return result
    }

    /// Circular reveal from the centre.
    func circleOpened(with other: PixelCanvas, progress: Double) -> PixelCanvas {
        var result = self
        let centerX = Double(width) / 2, centerY = Double(height) / 2
        let maxRadius = (centerX * centerX + centerY * centerY).squareRoot()
        let radius = maxRadius * min(max(progress, 0), 1)
        let radiusSquared = radius * radius

        for y in 0..<height {
            for x in 0..<width {
                let dx = Double(x) - centerX
                let dy = Double(y) - centerY
                let index = (y * width + x) * 4
                let source = (dx * dx + dy * dy) <= radiusSquared ? other.pixels : pixels
                result.pixels[index] = source[index]
                result.pixels[index + 1] = source[index + 1]
                result.pixels[index + 2] = source[index + 2]
                result.pixels[index + 3] = 255
            }
        }
        return result
    }
}
