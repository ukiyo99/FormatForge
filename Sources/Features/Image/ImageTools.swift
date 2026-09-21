import Foundation
import CoreGraphics
import AppKit
import PDFKit
import Vision
import CoreImage
import UniformTypeIdentifiers

/// Runs per-file work concurrently while keeping output order stable.
enum ConcurrentProcessor {
    static func run<T: Sendable>(
        _ items: [T],
        limit: Int = 0,
        reporter: ProgressReporter,
        operation: @escaping @Sendable (T, Int) async throws -> URL?
    ) async throws -> [URL] {
        guard !items.isEmpty else { return [] }
        let effective = limit > 0 ? limit : min(4, max(2, ProcessInfo.processInfo.activeProcessorCount / 2))

        return try await withThrowingTaskGroup(of: (Int, URL?).self) { group in
            var iterator = items.enumerated().makeIterator()
            var completed = 0

            for _ in 0..<min(effective, items.count) {
                guard let (index, item) = iterator.next() else { break }
                group.addTask { (index, try await operation(item, index)) }
            }

            var collected: [Int: URL] = [:]
            while let result = try await group.next() {
                completed += 1
                if let url = result.1 { collected[result.0] = url }
                reporter.report(Double(completed) / Double(items.count))
                if let (nextIndex, nextItem) = iterator.next() {
                    group.addTask { (nextIndex, try await operation(nextItem, nextIndex)) }
                }
            }
            return collected.keys.sorted().compactMap { collected[$0] }
        }
    }
}

// MARK: - 1. Format conversion

enum ImageConvertTool {
    static var tool: Tool { Tool(
        id: "image.convert",
        name: L("image.convert.name"),
        summary: L("image.convert.summary"),
        symbol: "arrow.left.arrow.right",
        category: .image,
        accepts: ["png", "jpg", "jpeg", "gif", "webp", "tiff", "tif", "bmp", "heic", "heif",
                  "avif", "ico", "icns", "psd", "tga", "jp2", "exr", "dng", "cr2", "nef", "arw", "raf"],
        actionTitle: L("ui.start"),
        parameters: [
            .picker("codec", L("image.convert.param.codec.label"), default: "jpeg", options: ImageCodec.allCases.map {
                PickerOption($0.rawValue, $0.label, detail: $0.detail)
            }),
            .slider("quality", L("pdf.toimage.param.quality.label"), default: 90, min: 10, max: 100, step: 1,
                    hint: L("image.convert.param.quality.hint"),
                    visibleWhen: .oneOf("codec", ["jpeg", "heic", "avif", "webp", "jp2"])),
            .slider("compression", L("image.convert.param.compression.label"), default: 60, min: 0, max: 100, step: 5,
                    hint: L("image.convert.param.compression.hint"),
                    visibleWhen: .oneOf("codec", ["png", "tiff"])),
            .picker("resize", L("image.convert.param.resize.label"), default: "keep", options: [
                .init("keep", L("enum.kind.lossless")), .init("maxWidth", L("image.convert.param.resize.label.2")),
                .init("maxHeight", L("image.convert.param.resize.label.3")), .init("percent", L("image.convert.param.resize.label.4")),
            ]),
            .number("maxWidth", L("image.convert.param.maxWidth.label"), default: 1920, min: 16, max: 20_000, step: 10,
                    visibleWhen: .equals("resize", "maxWidth")),
            .number("maxHeight", L("image.convert.param.maxHeight.label"), default: 1080, min: 16, max: 20_000, step: 10,
                    visibleWhen: .equals("resize", "maxHeight")),
            .slider("percent", L("image.convert.param.percent.label"), default: 50, min: 1, max: 400, step: 1,
                    visibleWhen: .equals("resize", "percent")),
            .number("dpi", L("image.convert.param.dpi.label"), default: 0, min: 0, max: 1200, step: 1),
            .toggle("flatten", L("image.convert.param.flatten.label"), default: true,
                    hint: L("image.convert.param.flatten.hint")),
            .toggle("stripMetadata", L("image.convert.param.stripMetadata.label"), default: false),
        ],
        run: { context in
            let codec = ImageCodec(rawValue: context.choice("codec", "jpeg")) ?? .jpeg
            let quality = context.double("quality", 90) / 100
            let compression = context.double("compression", 60) / 100
            let dpi = context.double("dpi", 0)
            let strip = context.bool("stripMetadata")
            let flatten = context.bool("flatten", true)
            let useNativeEncoder = ImageSupport.needsFFmpeg(codec)

            return try await ConcurrentProcessor.run(context.inputs, reporter: context.progress) { url, index in
                try context.checkCancelled()
                guard var image = ImageSupport.loadOriented(url) else {
                    throw ProcessError.failed(code: 0, message: L("image.convert.param.stripMetadata.label.2", url.lastPathComponent))
                }
                image = try ImageConvertTool.applyResize(image, context: context)
                if flatten && !codec.supportsAlpha {
                    image = ImageConvertTool.flatten(image) ?? image
                }

                let output = context.output(index: index, ext: codec.fileExtension, suffix: "")
                if useNativeEncoder {
                    try await ImageSupport.writeNonNative(
                        image, to: output, codec: codec, quality: quality, context: context)
                } else {
                    try ImageSupport.write(
                        image, to: output, codec: codec,
                        quality: quality, compression: compression,
                        dpi: dpi > 0 ? dpi : nil,
                        metadata: strip ? [:] : nil)
                }
                return output
            }
        }
    ) }

    static func applyResize(_ image: CGImage, context: ToolContext) throws -> CGImage {
        let mode = context.choice("resize", "keep")
        guard mode != "keep" else { return image }
        let width = Double(image.width), height = Double(image.height)

        switch mode {
        case "maxWidth":
            let maxWidth = context.double("maxWidth", 1920)
            guard width > maxWidth else { return image }
            return ImageSupport.resize(image,
                to: CGSize(width: maxWidth, height: height * maxWidth / width), fit: .stretch) ?? image
        case "maxHeight":
            let maxHeight = context.double("maxHeight", 1080)
            guard height > maxHeight else { return image }
            return ImageSupport.resize(image,
                to: CGSize(width: width * maxHeight / height, height: maxHeight), fit: .stretch) ?? image
        case "percent":
            return ImageSupport.scale(image, percent: context.double("percent", 50)) ?? image
        default:
            return image
        }
    }

    /// Composite onto an opaque white background.
    static func flatten(_ image: CGImage, background: NSColor = .white) -> CGImage? {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }
        context.setFillColor(background.usingColorSpace(.sRGB)?.cgColor ?? NSColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context.makeImage()
    }
}

extension ImageCodec {
    /// Whether the format can represent transparency.
    var supportsAlpha: Bool {
        switch self {
        case .png, .tiff, .gif, .webp, .heic, .avif, .ico, .icns, .tga, .exr: return true
        case .jpeg, .bmp, .pdf, .jp2: return false
        }
    }
}

// MARK: - 2. Compression

enum ImageCompressTool {
    static var tool: Tool { Tool(
        id: "image.compress",
        name: L("image.compress.name"),
        summary: L("image.compress.summary"),
        symbol: "arrow.down.circle",
        category: .image,
        accepts: ["png", "jpg", "jpeg", "heic", "avif", "webp", "tiff", "tif", "bmp", "gif"],
        actionTitle: L("archive.create.action"),
        parameters: [
            .picker("mode", L("image.compress.param.mode.label"), default: "quality", options: [
                .init("quality", L("image.compress.param.mode.label.2")), .init("targetSize", L("image.compress.param.mode.label.3")),
                .init("percent", L("image.compress.param.mode.label.4")),
            ]),
            .slider("quality", L("pdf.toimage.param.quality.label"), default: 75, min: 10, max: 100, step: 1,
                    hint: L("image.compress.param.quality.hint"),
                    visibleWhen: .equals("mode", "quality")),
            .number("targetKB", L("image.compress.param.targetKB.label"), default: 500, min: 5, max: 200_000, step: 10,
                    visibleWhen: .equals("mode", "targetSize")),
            .slider("percent", L("image.compress.param.percent.label"), default: 50, min: 5, max: 95, step: 5,
                    visibleWhen: .equals("mode", "percent")),
            .picker("format", L("doc.ocr.param.output.label"), default: "keep", options: [
                .init("keep", L("image.compress.param.format.label")), .init("jpeg", "JPEG"), .init("webp", "WebP"),
                .init("heic", "HEIC"), .init("png", "PNG"),
            ]),
            .picker("resize", L("image.convert.param.resize.label"), default: "keep", options: [
                .init("keep", L("enum.kind.lossless")), .init("maxWidth", L("image.convert.param.resize.label.2")),
                .init("maxHeight", L("image.convert.param.resize.label.3")), .init("percent", L("image.convert.param.resize.label.4")),
            ]),
            .number("maxWidth", L("image.convert.param.maxWidth.label"), default: 1920, min: 16, max: 20_000, step: 10,
                    visibleWhen: .equals("resize", "maxWidth")),
            .number("maxHeight", L("image.convert.param.maxHeight.label"), default: 1080, min: 16, max: 20_000, step: 10,
                    visibleWhen: .equals("resize", "maxHeight")),
            .slider("scalePercent", L("image.convert.param.percent.label"), default: 70, min: 5, max: 100, step: 5,
                    visibleWhen: .equals("resize", "percent")),
        ],
        run: { context in
            let mode = context.choice("mode", "quality")
            let requestedFormat = context.choice("format", "keep")
            let originalBytes = context.inputs.reduce(Int64(0)) { $0 + FileIO.size(of: $1) }

            let outputs = try await ConcurrentProcessor.run(context.inputs, reporter: context.progress) { url, index in
                try context.checkCancelled()
                guard var image = ImageSupport.loadOriented(url) else {
                    throw ProcessError.failed(code: 0, message: L("image.convert.param.stripMetadata.label.2", url.lastPathComponent))
                }
                image = try ImageConvertTool.applyResize(image, context: context)

                var codec: ImageCodec
                if requestedFormat == "keep" {
                    codec = ImageCodec.from(extension: url.pathExtension) ?? .jpeg
                    if codec == .tiff { codec = .jpeg }
                } else {
                    codec = ImageCodec(rawValue: requestedFormat) ?? .jpeg
                }
                // PNG is lossless; re-encoding it usually grows the file.
                if codec == .png && mode != "percent" { codec = .jpeg }
                if !codec.supportsAlpha {
                    image = ImageConvertTool.flatten(image) ?? image
                }

                let output = context.output(index: index, ext: codec.fileExtension, suffix: L("doc.pdfcompress.param.grayscale.label.2"))
                let quality = try ImageCompressTool.resolveQuality(
                    mode: mode, context: context, image: image,
                    codec: codec, output: output, sourceBytes: FileIO.size(of: url))

                if ImageSupport.needsFFmpeg(codec) {
                    try await ImageSupport.writeNonNative(
                        image, to: output, codec: codec, quality: quality, context: context)
                } else {
                    try ImageSupport.write(image, to: output, codec: codec, quality: quality)
                }
                return output
            }

            let outputBytes = outputs.reduce(Int64(0)) { $0 + FileIO.size(of: $1) }
            if originalBytes > 0, outputBytes > 0 {
                let saved = 1 - Double(outputBytes) / Double(originalBytes)
                context.progress.note(String(format: L("image.compress.param.scalePercent.label"), saved * 100))
            }
            return outputs
        }
    ) }

    /// Binary-search the encoder quality so the result lands near the target size.
    private static func resolveQuality(
        mode: String, context: ToolContext, image: CGImage,
        codec: ImageCodec, output: URL, sourceBytes: Int64
    ) throws -> Double {
        switch mode {
        case "quality":
            return context.double("quality", 75) / 100

        case "percent":
            // Encode at a moderate quality, then estimate the quality that
            // reaches the requested fraction of the original size.
            let target = Double(sourceBytes) * context.double("percent", 50) / 100
            return try searchQuality(image: image, codec: codec, targetBytes: target, output: output)

        default:
            let target = context.double("targetKB", 500) * 1024
            return try searchQuality(image: image, codec: codec, targetBytes: target, output: output)
        }
    }

    /// Six-step binary search over quality, encoding to a scratch file each time.
    private static func searchQuality(
        image: CGImage, codec: ImageCodec, targetBytes: Double, output: URL
    ) throws -> Double {
        let scratch = try FileIO.makeScratchDirectory()
        defer { FileIO.removeQuietly(scratch) }
        let probe = scratch.appendingPathComponent("probe.\(codec.fileExtension)")

        var low = 0.05, high = 1.0
        var best = 0.7

        for _ in 0..<7 {
            let mid = (low + high) / 2
            try? FileManager.default.removeItem(at: probe)
            do {
                try ImageSupport.write(image, to: probe, codec: codec, quality: mid)
            } catch {
                break
            }
            let size = Double(FileIO.size(of: probe))
            best = mid
            if size > targetBytes {
                high = mid
            } else {
                low = mid
            }
            if abs(size - targetBytes) / max(targetBytes, 1) < 0.08 { break }
        }
        return min(max(best, 0.05), 1.0)
    }
}

// MARK: - 3. Resize

enum ImageResizeTool {
    static var tool: Tool { Tool(
        id: "image.resize",
        name: L("image.resize.name"),
        summary: L("image.resize.summary"),
        symbol: "arrow.up.left.and.arrow.down.right",
        category: .image,
        accepts: ["png", "jpg", "jpeg", "gif", "webp", "tiff", "tif", "bmp", "heic", "heif", "avif", "ico"],
        actionTitle: L("image.resize.action"),
        parameters: [
            .picker("mode", L("image.resize.param.mode.label"), default: "width", options: [
                .init("width", L("image.resize.param.mode.label.2")), .init("height", L("image.resize.param.mode.label.3")),
                .init("exact", L("image.resize.param.mode.label.4")), .init("percent", L("image.resize.param.mode.label.5")),
                .init("longEdge", L("image.resize.param.mode.label.6")),
            ]),
            .number("width", L("image.resize.param.width.label"), default: 1920, min: 1, max: 20_000, step: 1,
                    visibleWhen: .oneOf("mode", ["width", "exact"])),
            .number("height", L("image.resize.param.height.label"), default: 1080, min: 1, max: 20_000, step: 1,
                    visibleWhen: .oneOf("mode", ["height", "exact"])),
            .slider("percent", L("image.convert.param.percent.label"), default: 50, min: 1, max: 400, step: 1,
                    visibleWhen: .equals("mode", "percent")),
            .number("longEdge", L("image.resize.param.longEdge.label"), default: 1600, min: 1, max: 20_000, step: 1,
                    visibleWhen: .equals("mode", "longEdge")),
            .picker("fit", L("image.resize.param.fit.label"), default: "stretch", options: ImageFit.allCases.map {
                PickerOption($0.rawValue, $0.label)
            }, visibleWhen: .equals("mode", "exact")),
            .toggle("onlyShrink", L("image.resize.param.onlyShrink.label"), default: true),
            .number("dpi", L("image.convert.param.dpi.label"), default: 0, min: 0, max: 1200, step: 1),
            .picker("format", L("doc.ocr.param.output.label"), default: "keep", options: [
                .init("keep", L("image.compress.param.format.label")), .init("png", "PNG"), .init("jpeg", "JPEG"), .init("webp", "WebP"),
            ]),
        ],
        run: { context in
            let requested = context.choice("format", "keep")
            let dpi = context.double("dpi", 0)
            let onlyShrink = context.bool("onlyShrink", true)

            return try await ConcurrentProcessor.run(context.inputs, reporter: context.progress) { url, index in
                try context.checkCancelled()
                guard let image = ImageSupport.loadOriented(url) else {
                    throw ProcessError.failed(code: 0, message: L("image.convert.param.stripMetadata.label.2", url.lastPathComponent))
                }

                let source = CGSize(width: image.width, height: image.height)
                var target = ImageResizeTool.targetSize(source: source, context: context)
                if onlyShrink {
                    target.width = min(target.width, source.width)
                    target.height = min(target.height, source.height)
                }
                target.width = max(target.width.rounded(), 1)
                target.height = max(target.height.rounded(), 1)

                let fit: ImageFit = context.choice("mode", "width") == "exact"
                    ? (ImageFit(rawValue: context.choice("fit", "stretch")) ?? .stretch)
                    : .stretch

                guard let resized = ImageSupport.resize(image, to: target, fit: fit) else {
                    throw ProcessError.failed(code: 0, message: L("image.resize.param.format.label", url.lastPathComponent))
                }

                let codec = requested == "keep"
                    ? (ImageCodec.from(extension: url.pathExtension) ?? .png)
                    : (ImageCodec(rawValue: requested) ?? .png)
                let output = context.output(index: index, ext: codec.fileExtension, suffix: "_\(Int(target.width))")

                if ImageSupport.needsFFmpeg(codec) {
                    try await ImageSupport.writeNonNative(
                        resized, to: output, codec: codec, quality: 0.92, context: context)
                } else {
                    try ImageSupport.write(resized, to: output, codec: codec,
                                           quality: 0.92, dpi: dpi > 0 ? dpi : nil)
                }
                return output
            }
        }
    ) }

    static func targetSize(source: CGSize, context: ToolContext) -> CGSize {
        switch context.choice("mode", "width") {
        case "height":
            let height = context.double("height", 1080)
            return CGSize(width: source.width * height / source.height, height: height)
        case "exact":
            return CGSize(width: context.double("width", 1920), height: context.double("height", 1080))
        case "percent":
            let percent = context.double("percent", 50) / 100
            return CGSize(width: source.width * percent, height: source.height * percent)
        case "longEdge":
            let edge = context.double("longEdge", 1600)
            let longest = max(source.width, source.height)
            guard longest > 0 else { return source }
            let scale = edge / longest
            return CGSize(width: source.width * scale, height: source.height * scale)
        default:
            let width = context.double("width", 1920)
            return CGSize(width: width, height: source.height * width / max(source.width, 1))
        }
    }
}

// MARK: - 4. Crop / rotate / flip

enum ImageTransformTool {
    static var tool: Tool { Tool(
        id: "image.transform",
        name: L("image.transform.name"),
        summary: L("image.transform.summary"),
        symbol: "crop.rotate",
        category: .image,
        accepts: ["png", "jpg", "jpeg", "gif", "webp", "tiff", "tif", "bmp", "heic", "avif"],
        actionTitle: L("image.transform.action"),
        parameters: [
            .picker("crop", L("image.transform.param.crop.label"), default: "none", options: [
                .init("none", L("image.transform.param.crop.label.2")), .init("aspect", L("image.transform.param.crop.label.3")),
                .init("percent", L("image.transform.param.crop.label.4")),
            ]),
            .picker("aspect", L("image.transform.param.aspect.label"), default: "1:1", options: [
                .init("1:1", L("image.transform.param.aspect.label.2")), .init("4:3", "4:3"), .init("3:4", "3:4"),
                .init("16:9", "16:9"), .init("9:16", "9:16"), .init("3:2", "3:2"), .init("2:3", "2:3"),
            ], visibleWhen: .equals("crop", "aspect")),
            .slider("insetPercent", L("image.transform.param.insetPercent.label"), default: 10, min: 0, max: 45, step: 1,
                    visibleWhen: .equals("crop", "percent")),
            .picker("rotate", L("ui.rotation"), default: "0", options: [
                .init("0", L("image.transform.param.rotate.label")), .init("90", L("image.transform.param.rotate.label.2")),
                .init("180", "180°"), .init("270", L("image.transform.param.rotate.label.3")),
            ]),
            .toggle("flipH", L("image.transform.param.flipH.label"), default: false),
            .toggle("flipV", L("image.transform.param.flipV.label"), default: false),
            .picker("format", L("doc.ocr.param.output.label"), default: "keep", options: [
                .init("keep", L("image.compress.param.format.label")), .init("png", "PNG"), .init("jpeg", "JPEG"), .init("webp", "WebP"),
            ]),
        ],
        run: { context in
            let requested = context.choice("format", "keep")
            return try await ConcurrentProcessor.run(context.inputs, reporter: context.progress) { url, index in
                try context.checkCancelled()
                guard var image = ImageSupport.loadOriented(url) else {
                    throw ProcessError.failed(code: 0, message: L("image.convert.param.stripMetadata.label.2", url.lastPathComponent))
                }

                // Crop first, then rotate/flip.
                switch context.choice("crop", "none") {
                case "aspect":
                    let parts = context.choice("aspect", "1:1").split(separator: ":")
                    if parts.count == 2,
                       let rw = Double(parts[0]), let rh = Double(parts[1]), rh > 0 {
                        image = ImageTransformTool.centerCrop(image, ratio: rw / rh) ?? image
                    }
                case "percent":
                    let inset = context.double("insetPercent", 10) / 100
                    let rect = CGRect(
                        x: Double(image.width) * inset,
                        y: Double(image.height) * inset,
                        width: Double(image.width) * (1 - inset * 2),
                        height: Double(image.height) * (1 - inset * 2))
                    image = ImageSupport.crop(image, rect: rect) ?? image
                default:
                    break
                }

                let rotation = Int(context.choice("rotate", "0")) ?? 0
                let flipH = context.bool("flipH")
                let flipV = context.bool("flipV")
                if rotation != 0 || flipH || flipV {
                    image = ImageSupport.transform(image, rotation: rotation,
                                                   flipHorizontal: flipH, flipVertical: flipV) ?? image
                }

                let codec = requested == "keep"
                    ? (ImageCodec.from(extension: url.pathExtension) ?? .png)
                    : (ImageCodec(rawValue: requested) ?? .png)
                let output = context.output(index: index, ext: codec.fileExtension, suffix: L("image.transform.param.format.label"))

                if ImageSupport.needsFFmpeg(codec) {
                    try await ImageSupport.writeNonNative(
                        image, to: output, codec: codec, quality: 0.92, context: context)
                } else {
                    try ImageSupport.write(image, to: output, codec: codec, quality: 0.92)
                }
                return output
            }
        }
    ) }

    /// Crop to the largest centred rectangle of the given aspect ratio.
    static func centerCrop(_ image: CGImage, ratio: Double) -> CGImage? {
        let width = Double(image.width), height = Double(image.height)
        let current = width / height
        var cropWidth = width, cropHeight = height
        if current > ratio {
            cropWidth = height * ratio
        } else {
            cropHeight = width / ratio
        }
        let rect = CGRect(
            x: (width - cropWidth) / 2,
            y: (height - cropHeight) / 2,
            width: cropWidth, height: cropHeight)
        return ImageSupport.crop(image, rect: rect)
    }
}

// MARK: - 5. Watermark

enum ImageWatermarkTool {
    static var tool: Tool { Tool(
        id: "image.watermark",
        name: L("image.watermark.name"),
        summary: L("image.watermark.summary"),
        symbol: "signature",
        category: .image,
        accepts: ["png", "jpg", "jpeg", "tiff", "tif", "bmp", "heic", "webp", "gif", "avif"],
        actionTitle: L("image.watermark.action"),
        parameters: [
            .picker("kind", L("image.watermark.param.kind.label"), default: "text", options: [
                .init("text", L("image.watermark.param.kind.label.2")), .init("image", L("image.watermark.name")),
            ]),
            .text("text", L("image.watermark.param.text.label"), default: "© FormatForge",
                  visibleWhen: .equals("kind", "text")),
            .slider("fontSize", L("image.watermark.param.fontSize.label"), default: 5, min: 1, max: 30, step: 0.5,
                    hint: L("image.watermark.param.fontSize.hint"),
                    visibleWhen: .equals("kind", "text")),
            .text("color", L("image.watermark.param.color.label"), default: "#FFFFFF",
                  hint: L("image.watermark.param.color.hint"),
                  visibleWhen: .equals("kind", "text")),
            .slider("imageScale", L("image.watermark.param.imageScale.label"), default: 20, min: 1, max: 100, step: 1,
                    visibleWhen: .equals("kind", "image")),
            .picker("position", L("ui.location"), default: "bottomRight", options: WatermarkPosition.allCases.map {
                PickerOption($0.rawValue, $0.label)
            }),
            .slider("opacity", L("image.watermark.param.opacity.label"), default: 70, min: 5, max: 100, step: 5),
            .number("margin", L("image.watermark.param.margin.label"), default: 4, min: 0, max: 40, step: 0.5),
        ],
        minimumInputs: 2,
        run: { context in
            let isImageWatermark = context.choice("kind", "text") == "image"
            var images = context.inputs
            var overlay: CGImage?

            if isImageWatermark {
                guard let overlayURL = context.inputs.last,
                      overlayURL.fileExtensionLower.isImageExtension,
                      let loaded = ImageSupport.loadOriented(overlayURL)
                else {
                    throw ProcessError.failed(code: 0, message: L("image.watermark.param.margin.label.2"))
                }
                overlay = loaded
                images = Array(context.inputs.dropLast())
            }
            guard !images.isEmpty else {
                throw ProcessError.failed(code: 0, message: L("image.watermark.param.margin.label.3"))
            }

            let color = ImageSupport.nsColor(from: context.string("color", "#FFFFFF"))
            let position = WatermarkPosition(rawValue: context.choice("position", "bottomRight")) ?? .bottomRight
            let opacity = context.double("opacity", 70) / 100
            let marginPercent = context.double("margin", 4) / 100
            let fontSizePercent = context.double("fontSize", 5) / 100
            let overlayScale = context.double("imageScale", 20) / 100

            return try await ConcurrentProcessor.run(images, reporter: context.progress) { url, index in
                try context.checkCancelled()
                guard let base = ImageSupport.loadOriented(url) else {
                    throw ProcessError.failed(code: 0, message: L("image.convert.param.stripMetadata.label.2", url.lastPathComponent))
                }
                let result = ImageSupport.watermark(
                    base,
                    text: isImageWatermark ? nil : context.string("text", "© FormatForge"),
                    textColor: color,
                    fontSize: max(Double(base.width) * fontSizePercent, 8),
                    image: overlay,
                    overlayScale: overlayScale,
                    position: position,
                    opacity: opacity,
                    margin: Double(base.width) * marginPercent
                )
                guard let result else {
                    throw ProcessError.failed(code: 0, message: L("image.watermark.param.margin.label.4", url.lastPathComponent))
                }

                let codec = ImageCodec.from(extension: url.pathExtension) ?? .png
                let output = context.output(index: index, ext: codec.fileExtension, suffix: L("image.watermark.param.margin.label.5"))
                if ImageSupport.needsFFmpeg(codec) {
                    try await ImageSupport.writeNonNative(
                        result, to: output, codec: codec, quality: 0.92, context: context)
                } else {
                    try ImageSupport.write(result, to: output, codec: codec, quality: 0.92)
                }
                return output
            }
        }
    ) }
}

// MARK: - 6. Stitch / collage

enum ImageStitchTool {
    static var tool: Tool { Tool(
        id: "image.stitch",
        name: L("image.stitch.name"),
        summary: L("image.stitch.summary"),
        symbol: "square.grid.2x2",
        category: .image,
        accepts: ["png", "jpg", "jpeg", "tiff", "tif", "bmp", "heic", "webp", "gif", "avif"],
        actionTitle: L("image.stitch.action"),
        parameters: [
            .picker("layout", L("image.stitch.param.layout.label"), default: "vertical", options: StitchLayout.allCases.map {
                PickerOption($0.rawValue, $0.label)
            }),
            .number("columns", L("image.stitch.param.columns.label"), default: 3, min: 1, max: 20, step: 1,
                    visibleWhen: .equals("layout", "grid")),
            .slider("spacing", L("image.stitch.param.spacing.label"), default: 8, min: 0, max: 200, step: 1),
            .text("background", L("ui.background"), default: "#FFFFFF",
                  hint: L("image.watermark.param.color.hint")),
            .number("cellWidth", L("image.stitch.param.cellWidth.label"), default: 0, min: 0, max: 10_000, step: 10),
            .picker("format", L("doc.ocr.param.output.label"), default: "png", options: [
                .init("png", "PNG"), .init("jpeg", "JPEG"), .init("webp", "WebP"),
            ]),
            .slider("quality", L("pdf.toimage.param.quality.label"), default: 92, min: 40, max: 100, step: 1,
                    visibleWhen: .oneOf("format", ["jpeg", "webp"])),
        ],
        minimumInputs: 2,
        run: { context in
            var images: [CGImage] = []
            for url in context.inputs {
                try context.checkCancelled()
                if let image = ImageSupport.loadOriented(url) { images.append(image) }
            }
            guard images.count >= 2 else {
                throw ProcessError.failed(code: 0, message: L("image.stitch.param.quality.label"))
            }
            context.progress.report(0.3)

            let layout = StitchLayout(rawValue: context.choice("layout", "vertical")) ?? .vertical
            let cellWidth = context.int("cellWidth", 0)
            guard let result = ImageSupport.stitch(
                images,
                layout: layout,
                columns: context.int("columns", 3),
                spacing: context.double("spacing", 8),
                background: ImageSupport.cgColor(ImageSupport.nsColor(from: context.string("background", "#FFFFFF"))),
                targetCellWidth: cellWidth > 0 ? cellWidth : nil
            ) else {
                throw ProcessError.failed(code: 0, message: L("image.stitch.param.quality.label.2"))
            }
            context.progress.report(0.8)

            let codec = ImageCodec(rawValue: context.choice("format", "png")) ?? .png
            let output = context.output(ext: codec.fileExtension, suffix: L("image.stitch.param.quality.label.3"))
            if ImageSupport.needsFFmpeg(codec) {
                try await ImageSupport.writeNonNative(
                    result, to: output, codec: codec,
                    quality: context.double("quality", 92) / 100, context: context)
            } else {
                try ImageSupport.write(result, to: output, codec: codec,
                                       quality: context.double("quality", 92) / 100)
            }
            return [output]
        }
    ) }
}

// MARK: - 7. Rounded corners / border / shadow

enum ImageDecorateTool {
    static var tool: Tool { Tool(
        id: "image.decorate",
        name: L("image.decorate.name"),
        summary: L("image.decorate.summary"),
        symbol: "square.on.circle",
        category: .image,
        accepts: ["png", "jpg", "jpeg", "tiff", "tif", "bmp", "heic", "webp"],
        actionTitle: L("image.decorate.action"),
        parameters: [
            .slider("cornerRadius", L("image.decorate.param.cornerRadius.label"), default: 4, min: 0, max: 50, step: 0.5),
            .slider("borderWidth", L("image.decorate.param.borderWidth.label"), default: 0, min: 0, max: 100, step: 1),
            .text("borderColor", L("image.decorate.param.borderColor.label"), default: "#FFFFFF"),
            .toggle("shadow", L("image.decorate.param.shadow.label"), default: true),
            .text("background", L("image.decorate.param.background.label"), default: ""),
            .picker("format", L("doc.ocr.param.output.label"), default: "png", options: [
                .init("png", L("image.decorate.param.format.label")), .init("jpeg", "JPEG"), .init("webp", "WebP"),
            ]),
        ],
        run: { context in
            let backgroundString = context.string("background", "")
            let background = backgroundString.isEmpty
                ? CGColor(red: 0, green: 0, blue: 0, alpha: 0)
                : ImageSupport.cgColor(ImageSupport.nsColor(from: backgroundString))
            let codec = ImageCodec(rawValue: context.choice("format", "png")) ?? .png

            return try await ConcurrentProcessor.run(context.inputs, reporter: context.progress) { url, index in
                try context.checkCancelled()
                guard let image = ImageSupport.loadOriented(url) else {
                    throw ProcessError.failed(code: 0, message: L("image.convert.param.stripMetadata.label.2", url.lastPathComponent))
                }
                let radius = Double(image.width) * context.double("cornerRadius", 4) / 100
                guard let result = ImageSupport.decorate(
                    image,
                    cornerRadius: radius,
                    borderWidth: context.double("borderWidth", 0),
                    borderColor: ImageSupport.cgColor(ImageSupport.nsColor(from: context.string("borderColor", "#FFFFFF"))),
                    shadow: context.bool("shadow", true),
                    background: background
                ) else {
                    throw ProcessError.failed(code: 0, message: L("image.decorate.param.format.label.2", url.lastPathComponent))
                }

                let output = context.output(index: index, ext: codec.fileExtension, suffix: L("image.decorate.param.format.label.3"))
                if ImageSupport.needsFFmpeg(codec) {
                    try await ImageSupport.writeNonNative(
                        result, to: output, codec: codec, quality: 0.92, context: context)
                } else {
                    try ImageSupport.write(result, to: output, codec: codec, quality: 0.92)
                }
                return output
            }
        }
    ) }
}
