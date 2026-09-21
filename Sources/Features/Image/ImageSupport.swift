import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import AppKit
import CoreImage

// MARK: - Codecs

/// Every image format the app can write, mapped onto ImageIO identifiers.
enum ImageCodec: String, CaseIterable, Identifiable, Sendable {
    case png, jpeg, heic, avif, tiff, gif, bmp, webp, ico, icns, pdf, jp2, tga, exr

    var id: String { rawValue }

    var label: String {
        switch self {
        case .png: return "PNG"
        case .jpeg: return "JPEG"
        case .heic: return "HEIC"
        case .avif: return "AVIF"
        case .tiff: return "TIFF"
        case .gif: return "GIF"
        case .bmp: return "BMP"
        case .webp: return "WebP"
        case .ico: return "ICO"
        case .icns: return "ICNS"
        case .pdf: return "PDF"
        case .jp2: return "JPEG 2000"
        case .tga: return "TGA"
        case .exr: return "EXR"
        }
    }

    var uti: String {
        switch self {
        case .png: return "public.png"
        case .jpeg: return "public.jpeg"
        case .heic: return "public.heic"
        case .avif: return "public.avif"
        case .tiff: return "public.tiff"
        case .gif: return "com.compuserve.gif"
        case .bmp: return "com.microsoft.bmp"
        case .webp: return "org.webmproject.webp"
        case .ico: return "com.microsoft.ico"
        case .icns: return "com.apple.icns"
        case .pdf: return "com.adobe.pdf"
        case .jp2: return "public.jpeg-2000"
        case .tga: return "com.truevision.tga-image"
        case .exr: return "com.ilm.openexr-image"
        }
    }

    var fileExtension: String {
        switch self {
        case .jpeg: return "jpg"
        case .jp2: return "jp2"
        default: return rawValue
        }
    }

    /// Resolve a codec from a file extension, accepting common aliases
    /// (`jpg` → `.jpeg`, `tif` → `.tiff`).
    static func from(extension ext: String) -> ImageCodec? {
        let lowered = ext.lowercased()
        switch lowered {
        case "jpg", "jpe": return .jpeg
        case "tif": return .tiff
        case "j2k", "jpf", "jpx": return .jp2
        case "heif": return .heic
        default: return ImageCodec(rawValue: lowered)
        }
    }

    var detail: String {
        switch self {
        case .png: return L("enum.imagecodec.png")
        case .jpeg: return L("enum.imagecodec.png.2")
        case .heic: return L("enum.imagecodec.png.3")
        case .avif: return L("enum.imagecodec.png.4")
        case .tiff: return L("enum.imagecodec.png.5")
        case .gif: return L("enum.imagecodec.png.6")
        case .bmp: return L("enum.imagecodec.png.7")
        case .webp: return L("enum.imagecodec.png.8")
        case .ico: return L("enum.imagecodec.png.9")
        case .icns: return L("enum.imagecodec.png.10")
        case .pdf: return L("enum.imagecodec.png.11")
        case .jp2: return "JPEG 2000"
        case .tga: return "Targa"
        case .exr: return L("enum.imagecodec.png.12")
        }
    }

    /// Whether ImageIO can write this type natively on this system.
    var isNativelyWritable: Bool {
        (CGImageDestinationCopyTypeIdentifiers() as? [String])?.contains(uti) ?? false
    }

    var supportsQuality: Bool {
        switch self {
        case .jpeg, .heic, .avif, .jp2, .webp: return true
        default: return false
        }
    }

    var supportsCompression: Bool {
        switch self {
        case .png, .tiff: return true
        default: return false
        }
    }
}

// MARK: - Fit modes

enum ImageFit: String, CaseIterable, Identifiable, Sendable {
    case contain, cover, stretch, pad

    var id: String { rawValue }

    var label: String {
        switch self {
        case .contain: return L("enum.fit.contain")
        case .cover: return L("enum.fitmode.contain.2")
        case .stretch: return L("enum.fitmode.contain.3")
        case .pad: return L("enum.fit.contain.2")
        }
    }
}

// MARK: - Image support

enum ImageSupport {

    // MARK: Loading

    static func load(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceShouldCache: false,
            kCGImageSourceShouldAllowFloat: true,
        ]
        return CGImageSourceCreateImageAtIndex(source, 0, options as CFDictionary)
    }

    static func loadOriented(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let orientation = properties[kCGImagePropertyOrientation] as? UInt32,
              orientation != 1
        else { return image }
        return applyOrientation(image, orientation: orientation)
    }

    static func size(of url: URL) -> CGSize? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else { return nil }
        let w = props[kCGImagePropertyPixelWidth] as? Int ?? 0
        let h = props[kCGImagePropertyPixelHeight] as? Int ?? 0
        return w > 0 && h > 0 ? CGSize(width: w, height: h) : nil
    }

    static func metadata(of url: URL) -> [String: String] {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else { return [:] }

        var result: [String: String] = [:]
        if let w = props[kCGImagePropertyPixelWidth] as? Int,
           let h = props[kCGImagePropertyPixelHeight] as? Int {
            result[L("ui.dimensions")] = "\(w) × \(h)"
        }
        if let dpiW = props[kCGImagePropertyDPIWidth] as? Double {
            result[L("ui.dimensions")] = String(format: "%.0f DPI", dpiW)
        }
        if let type = CGImageSourceGetType(source) as String? {
            result[L("ui.format")] = UTType(type)?.preferredFilenameExtension?.uppercased() ?? type
        }
        if let depth = props[kCGImagePropertyDepth] as? Int { result[L("ui.bit_depth")] = "\(depth) bit" }
        if let alpha = props[kCGImagePropertyHasAlpha] as? Bool {
            result[L("ui.transparency")] = alpha ? L("ui.yes") : L("enum.transition.none")
        }
        if let colorModel = props[kCGImagePropertyColorModel] as? String {
            result[L("ui.colour_model")] = colorModel
        }
        if let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            if let make = exif[kCGImagePropertyExifLensMake] as? String { result[L("ui.make")] = make }
            if let exposure = exif[kCGImagePropertyExifExposureTime] as? Double {
                result[L("ui.exposure")] = String(format: "1/%.0f s", 1 / max(exposure, 0.0001))
            }
            if let fNumber = exif[kCGImagePropertyExifFNumber] as? Double {
                result[L("ui.aperture")] = String(format: "f/%.1f", fNumber)
            }
            if let iso = exif[kCGImagePropertyExifISOSpeedRatings] as? [Int], let first = iso.first {
                result["ISO"] = "\(first)"
            }
        }
        if let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any],
           let model = tiff[kCGImagePropertyTIFFModel] as? String {
            result[L("ui.model")] = model
        }
        if let gps = props[kCGImagePropertyGPSDictionary] as? [CFString: Any],
           let lat = gps[kCGImagePropertyGPSLatitude] as? Double,
           let lon = gps[kCGImagePropertyGPSLongitude] as? Double {
            result["GPS"] = String(format: "%.5f, %.5f", lat, lon)
        }
        return result
    }

    // MARK: Writing

    /// Write a CGImage with the requested codec and options.
    @discardableResult
    static func write(
        _ image: CGImage,
        to url: URL,
        codec: ImageCodec,
        quality: Double = 0.9,
        compression: Double = 0.5,
        dpi: Double? = nil,
        metadata: [CFString: Any]? = nil
    ) throws -> URL {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, codec.uti as CFString, 1, nil
        ) else {
            throw ProcessError.failed(code: 0, message: L("ui.could_not_create_codec_label_output_the_fo", codec.label))
        }

        var properties: [CFString: Any] = metadata ?? [:]
        if codec.supportsQuality {
            properties[kCGImageDestinationLossyCompressionQuality] = quality
        }
        if codec.supportsCompression {
            // ImageIO's PNG encoder maps 0 (fast) → 1 (smallest).
            properties[kCGImageDestinationLossyCompressionQuality] = 1 - compression
        }
        if let dpi {
            properties[kCGImagePropertyDPIWidth] = dpi
            properties[kCGImagePropertyDPIHeight] = dpi
        }

        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw ProcessError.failed(code: 0, message: L("ui.could_not_write_codec_label", codec.label))
        }
        return url
    }

    /// Write formats ImageIO cannot emit. WebP goes through our own lossless
    /// VP8L encoder; anything else falls back to an ImageIO type or PNG.
    @discardableResult
    static func writeNonNative(
        _ image: CGImage,
        to url: URL,
        codec: ImageCodec,
        quality: Double,
        context: ToolContext?
    ) async throws -> URL {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        switch codec {
        case .webp:
            // Alpha-capable sources stay lossless only if the user asked for
            // it; otherwise lossy gives far smaller files.
            try WebPEncoder.encode(
                image, to: url, quality: quality,
                mode: quality >= 0.999 ? .lossless : .lossy)
            return url

        default:
            // Unknown target: fall back to PNG so the user still gets a file,
            // but name it honestly.
            try write(image, to: url, codec: .png)
            return url
        }
    }

    /// Whether the codec needs our own encoder rather than ImageIO.
    static func needsFFmpeg(_ codec: ImageCodec) -> Bool {
        !codec.isNativelyWritable
    }

    // MARK: Geometry

    /// Resize using CoreGraphics with high-quality interpolation.
    static func resize(_ image: CGImage, to target: CGSize, fit: ImageFit,
                       background: CGColor = CGColor(red: 0, green: 0, blue: 0, alpha: 0)) -> CGImage? {
        let targetWidth = max(Int(target.width.rounded()), 1)
        let targetHeight = max(Int(target.height.rounded()), 1)
        let sourceWidth = CGFloat(image.width)
        let sourceHeight = CGFloat(image.height)
        guard sourceWidth > 0, sourceHeight > 0 else { return nil }

        let colorSpace = image.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: targetWidth,
            height: targetHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        context.interpolationQuality = .high
        let targetRect = CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight)

        switch fit {
        case .stretch:
            context.draw(image, in: targetRect)

        case .contain, .pad:
            let scale = min(CGFloat(targetWidth) / sourceWidth, CGFloat(targetHeight) / sourceHeight)
            let drawWidth = sourceWidth * scale
            let drawHeight = sourceHeight * scale
            let rect = CGRect(
                x: (CGFloat(targetWidth) - drawWidth) / 2,
                y: (CGFloat(targetHeight) - drawHeight) / 2,
                width: drawWidth, height: drawHeight)
            if fit == .pad {
                context.setFillColor(background)
                context.fill(targetRect)
            }
            context.draw(image, in: rect)

        case .cover:
            let scale = max(CGFloat(targetWidth) / sourceWidth, CGFloat(targetHeight) / sourceHeight)
            let drawWidth = sourceWidth * scale
            let drawHeight = sourceHeight * scale
            let rect = CGRect(
                x: (CGFloat(targetWidth) - drawWidth) / 2,
                y: (CGFloat(targetHeight) - drawHeight) / 2,
                width: drawWidth, height: drawHeight)
            context.clip(to: targetRect)
            context.draw(image, in: rect)
        }

        return context.makeImage()
    }

    /// Scale by a percentage, preserving aspect ratio.
    static func scale(_ image: CGImage, percent: Double) -> CGImage? {
        let target = CGSize(
            width: max(Double(image.width) * percent / 100, 1),
            height: max(Double(image.height) * percent / 100, 1))
        return resize(image, to: target, fit: .stretch)
    }

    /// Crop to a rectangle expressed in source pixel coordinates.
    static func crop(_ image: CGImage, rect: CGRect) -> CGImage? {
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let clipped = rect.intersection(bounds).integral
        guard clipped.width >= 1, clipped.height >= 1 else { return nil }
        return image.cropping(to: clipped)
    }

    /// Rotate by a multiple of 90° and/or flip.
    static func transform(_ image: CGImage, rotation: Int, flipHorizontal: Bool, flipVertical: Bool) -> CGImage? {
        let normalized = ((rotation % 360) + 360) % 360
        let swapsAxes = normalized == 90 || normalized == 270
        let outWidth = swapsAxes ? image.height : image.width
        let outHeight = swapsAxes ? image.width : image.height

        let colorSpace = image.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil, width: outWidth, height: outHeight,
            bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        context.interpolationQuality = .high
        context.translateBy(x: CGFloat(outWidth) / 2, y: CGFloat(outHeight) / 2)
        context.rotate(by: CGFloat(normalized) * .pi / 180)
        context.scaleBy(x: flipHorizontal ? -1 : 1, y: flipVertical ? -1 : 1)
        let drawRect = CGRect(
            x: -CGFloat(image.width) / 2, y: -CGFloat(image.height) / 2,
            width: CGFloat(image.width), height: CGFloat(image.height))
        context.draw(image, in: drawRect)
        return context.makeImage()
    }

    /// Rounded corners, optional border and drop shadow.
    static func decorate(
        _ image: CGImage,
        cornerRadius: Double,
        borderWidth: Double,
        borderColor: CGColor,
        shadow: Bool,
        background: CGColor
    ) -> CGImage? {
        let padding = shadow ? 40.0 : 0.0
        let width = Int(Double(image.width) + padding * 2)
        let height = Int(Double(image.height) + padding * 2)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        context.interpolationQuality = .high
        context.setFillColor(background)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        let rect = CGRect(x: padding, y: padding,
                          width: CGFloat(image.width), height: CGFloat(image.height))
        let path = CGPath(roundedRect: rect, cornerWidth: cornerRadius,
                          cornerHeight: cornerRadius, transform: nil)

        if shadow {
            context.saveGState()
            context.setShadow(offset: CGSize(width: 0, height: -8),
                              blur: 24,
                              color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.35))
            context.addPath(path)
            context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
            context.fillPath()
            context.restoreGState()
        }

        context.saveGState()
        context.addPath(path)
        context.clip()
        context.draw(image, in: rect)
        context.restoreGState()

        if borderWidth > 0 {
            context.addPath(path)
            context.setStrokeColor(borderColor)
            context.setLineWidth(borderWidth)
            context.strokePath()
        }

        return context.makeImage()
    }

    // MARK: Watermark

    /// Draw text or an image watermark onto a base image.
    static func watermark(
        _ base: CGImage,
        text: String?,
        textColor: NSColor,
        fontSize: Double,
        image overlay: CGImage?,
        overlayScale: Double,
        position: WatermarkPosition,
        opacity: Double,
        margin: Double
    ) -> CGImage? {
        let width = base.width, height = base.height
        let colorSpace = base.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        context.interpolationQuality = .high
        context.draw(base, in: CGRect(x: 0, y: 0, width: width, height: height))
        context.setAlpha(opacity)

        if let text, !text.isEmpty {
            let font = NSFont.systemFont(ofSize: fontSize, weight: .semibold)
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: textColor,
            ]
            let attributed = NSAttributedString(string: text, attributes: attributes)
            let line = CTLineCreateWithAttributedString(attributed)
            let bounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
            let point = position.origin(
                contentWidth: bounds.width, contentHeight: bounds.height,
                canvasWidth: CGFloat(width), canvasHeight: CGFloat(height),
                margin: CGFloat(margin))
            context.textPosition = point
            CTLineDraw(line, context)
        } else if let overlay {
            let targetWidth = Double(width) * overlayScale
            let targetHeight = targetWidth * Double(overlay.height) / Double(overlay.width)
            let point = position.origin(
                contentWidth: targetWidth, contentHeight: targetHeight,
                canvasWidth: CGFloat(width), canvasHeight: CGFloat(height),
                margin: CGFloat(margin))
            context.draw(overlay, in: CGRect(x: point.x, y: point.y,
                                             width: targetWidth, height: targetHeight))
        }

        return context.makeImage()
    }

    // MARK: Composition

    /// Lay images out in a grid or a single row/column.
    static func stitch(
        _ images: [CGImage],
        layout: StitchLayout,
        columns: Int,
        spacing: Double,
        background: CGColor,
        targetCellWidth: Int?
    ) -> CGImage? {
        guard !images.isEmpty else { return nil }

        let columnCount: Int
        let rowCount: Int
        switch layout {
        case .horizontal: columnCount = images.count; rowCount = 1
        case .vertical: columnCount = 1; rowCount = images.count
        case .grid:
            columnCount = max(1, columns)
            rowCount = Int(ceil(Double(images.count) / Double(columnCount)))
        }

        // Determine a uniform cell size.
        let cellWidth: Int
        let cellHeight: Int
        if let targetCellWidth, targetCellWidth > 0 {
            let aspect = Double(images[0].height) / Double(images[0].width)
            cellWidth = targetCellWidth
            cellHeight = max(Int(Double(targetCellWidth) * aspect), 1)
        } else if layout == .horizontal {
            cellHeight = images.map(\.height).max() ?? 1
            cellWidth = images.map { Int(Double($0.width) * Double(cellHeight) / Double($0.height)) }.max() ?? 1
        } else if layout == .vertical {
            cellWidth = images.map(\.width).max() ?? 1
            cellHeight = images.map { Int(Double($0.height) * Double(cellWidth) / Double($0.width)) }.max() ?? 1
        } else {
            cellWidth = images.map(\.width).max() ?? 1
            cellHeight = images.map(\.height).max() ?? 1
        }

        let gap = Int(spacing)
        let totalWidth = columnCount * cellWidth + max(columnCount - 1, 0) * gap
        let totalHeight = rowCount * cellHeight + max(rowCount - 1, 0) * gap

        guard let context = CGContext(
            data: nil, width: totalWidth, height: totalHeight,
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        context.interpolationQuality = .high
        context.setFillColor(background)
        context.fill(CGRect(x: 0, y: 0, width: totalWidth, height: totalHeight))

        for (index, image) in images.enumerated() {
            let column = index % columnCount
            let row = index / columnCount
            // CoreGraphics origin is bottom-left, so rows count upward.
            let x = column * (cellWidth + gap)
            let y = totalHeight - (row + 1) * cellHeight - row * gap

            let scaled = resize(image, to: CGSize(width: cellWidth, height: cellHeight), fit: .contain)
                ?? image
            context.draw(scaled, in: CGRect(x: x, y: y, width: cellWidth, height: cellHeight))
        }

        return context.makeImage()
    }

    // MARK: Colour helpers

    static func nsColor(from string: String) -> NSColor {
        let trimmed = string.trimmingCharacters(in: .whitespaces).lowercased()
        switch trimmed {
        case "black", L("enum.imagesupport.contain"): return .black
        case "white", L("enum.imagesupport.contain.2"): return .white
        case "red", L("enum.imagesupport.contain.3"): return .systemRed
        case "green", L("enum.imagesupport.contain.4"): return .systemGreen
        case "blue", L("enum.imagesupport.contain.5"): return .systemBlue
        case "yellow", L("enum.imagesupport.contain.6"): return .systemYellow
        case "orange", L("enum.imagesupport.contain.7"): return .systemOrange
        case "purple", L("enum.imagesupport.contain.8"): return .systemPurple
        case "gray", "grey", L("enum.imagesupport.contain.9"): return .systemGray
        default: break
        }

        if trimmed.hasPrefix("#") {
            let hex = String(trimmed.dropFirst())
            var value: UInt64 = 0
            if Scanner(string: hex).scanHexInt64(&value) {
                switch hex.count {
                case 6:
                    return NSColor(
                        red: CGFloat((value >> 16) & 0xFF) / 255,
                        green: CGFloat((value >> 8) & 0xFF) / 255,
                        blue: CGFloat(value & 0xFF) / 255, alpha: 1)
                case 8:
                    return NSColor(
                        red: CGFloat((value >> 24) & 0xFF) / 255,
                        green: CGFloat((value >> 16) & 0xFF) / 255,
                        blue: CGFloat((value >> 8) & 0xFF) / 255,
                        alpha: CGFloat(value & 0xFF) / 255)
                default: break
                }
            }
        }
        return .white
    }

    static func cgColor(_ color: NSColor) -> CGColor {
        color.usingColorSpace(.sRGB)?.cgColor ?? NSColor.white.cgColor
    }

    private static func applyOrientation(_ image: CGImage, orientation: UInt32) -> CGImage? {
        switch orientation {
        case 3: return transform(image, rotation: 180, flipHorizontal: false, flipVertical: false)
        case 6: return transform(image, rotation: 270, flipHorizontal: false, flipVertical: false)
        case 8: return transform(image, rotation: 90, flipHorizontal: false, flipVertical: false)
        default: return image
        }
    }
}

// MARK: - Supporting enums

enum WatermarkPosition: String, CaseIterable, Identifiable, Sendable {
    case topLeft, topRight, bottomLeft, bottomRight, center

    var id: String { rawValue }

    var label: String {
        switch self {
        case .topLeft: return L("enum.position.topleft")
        case .topRight: return L("enum.position.topleft.2")
        case .bottomLeft: return L("enum.position.topleft.3")
        case .bottomRight: return L("enum.position.topleft.4")
        case .center: return L("enum.position.topleft.5")
        }
    }

    /// Bottom-left origin, matching CoreGraphics.
    func origin(contentWidth: Double, contentHeight: Double,
                canvasWidth: CGFloat, canvasHeight: CGFloat, margin: CGFloat) -> CGPoint {
        let w = CGFloat(contentWidth), h = CGFloat(contentHeight)
        switch self {
        case .topLeft:
            return CGPoint(x: margin, y: canvasHeight - h - margin)
        case .topRight:
            return CGPoint(x: canvasWidth - w - margin, y: canvasHeight - h - margin)
        case .bottomLeft:
            return CGPoint(x: margin, y: margin)
        case .bottomRight:
            return CGPoint(x: canvasWidth - w - margin, y: margin)
        case .center:
            return CGPoint(x: (canvasWidth - w) / 2, y: (canvasHeight - h) / 2)
        }
    }
}

enum StitchLayout: String, CaseIterable, Identifiable, Sendable {
    case horizontal, vertical, grid

    var id: String { rawValue }

    var label: String {
        switch self {
        case .horizontal: return L("enum.stitch.horizontal")
        case .vertical: return L("enum.stitch.horizontal.2")
        case .grid: return L("enum.stitch.horizontal.3")
        }
    }
}
