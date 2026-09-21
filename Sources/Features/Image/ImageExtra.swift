import Foundation
import CoreGraphics
import AppKit
import PDFKit
import CoreImage
import Vision
import UniformTypeIdentifiers

// MARK: - 1. Images to PDF

enum ImageToPDFTool {
    static var tool: Tool { Tool(
        id: "image.topdf",
        name: L("image.topdf.name"),
        summary: L("image.topdf.summary"),
        symbol: "doc.badge.plus",
        category: .image,
        accepts: ["png", "jpg", "jpeg", "tiff", "tif", "bmp", "heic", "webp", "gif", "avif"],
        actionTitle: L("image.topdf.action"),
        parameters: [
            .picker("pageSize", L("image.topdf.param.pageSize.label"), default: "fit", options: [
                .init("fit", L("image.topdf.param.pageSize.label.2")), .init("a4", "A4"), .init("letter", "Letter"),
                .init("a3", "A3"), .init("square", L("image.topdf.param.pageSize.label.3")),
            ]),
            .picker("orientation", L("image.topdf.param.orientation.label"), default: "auto", options: [
                .init("auto", L("image.topdf.param.orientation.label.2")), .init("portrait", L("image.topdf.param.orientation.label.3")), .init("landscape", L("image.topdf.param.orientation.label.4")),
            ], visibleWhen: .notEquals("pageSize", "fit")),
            .slider("margin", L("image.topdf.param.margin.label"), default: 24, min: 0, max: 200, step: 4,
                    visibleWhen: .notEquals("pageSize", "fit")),
            .picker("fit", L("ui.image_fitting"), default: "contain", options: [
                .init("contain", L("enum.fitmode.contain")), .init("cover", L("enum.fitmode.contain.2")), .init("stretch", L("image.topdf.param.fit.label")),
            ], visibleWhen: .notEquals("pageSize", "fit")),
            .text("title", L("image.topdf.param.title.label"), default: ""),
            .text("author", L("image.topdf.param.author.label"), default: ""),
            .toggle("oneFilePerImage", L("image.topdf.param.oneFilePerImage.label"), default: false),
        ],
        run: { context in
            if context.bool("oneFilePerImage") {
                return try await ConcurrentProcessor.run(context.inputs, reporter: context.progress) { url, index in
                    try context.checkCancelled()
                    guard let image = ImageSupport.loadOriented(url) else {
                        throw ProcessError.failed(code: 0, message: L("image.topdf.param.oneFilePerImage.label.2", url.lastPathComponent))
                    }
                    let output = context.output(index: index, ext: "pdf", suffix: "")
                    try ImageToPDFTool.write(pages: [image], to: output, context: context)
                    return output
                }
            }

            var pages: [CGImage] = []
            for url in context.inputs {
                try context.checkCancelled()
                guard let image = ImageSupport.loadOriented(url) else { continue }
                pages.append(image)
                context.progress.report(Double(pages.count) / Double(context.inputs.count) * 0.4)
            }
            guard !pages.isEmpty else {
                throw ProcessError.failed(code: 0, message: L("image.topdf.param.oneFilePerImage.label.3"))
            }

            let output = context.output(ext: "pdf", suffix: "")
            try ImageToPDFTool.write(pages: pages, to: output, context: context)
            context.progress.report(1)
            return [output]
        }
    ) }

    static func write(pages: [CGImage], to url: URL, context: ToolContext) throws {
        let pageSize = context.choice("pageSize", "fit")
        let orientation = context.choice("orientation", "auto")
        let margin = context.double("margin", 24)
        let fit = context.choice("fit", "contain")

        var mediaBox: CGRect
        switch pageSize {
        case "a4": mediaBox = CGRect(x: 0, y: 0, width: 595, height: 842)
        case "letter": mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        case "a3": mediaBox = CGRect(x: 0, y: 0, width: 842, height: 1191)
        case "square": mediaBox = CGRect(x: 0, y: 0, width: 800, height: 800)
        default: mediaBox = .zero
        }

        guard let consumer = CGDataConsumer(url: url as CFURL) else {
            throw ProcessError.failed(code: 0, message: L("image.topdf.param.oneFilePerImage.label.4"))
        }

        var metadata: [CFString: Any] = [:]
        let title = context.string("title", "")
        let author = context.string("author", "")
        if !title.isEmpty { metadata[kCGPDFContextTitle] = title }
        if !author.isEmpty { metadata[kCGPDFContextAuthor] = author }

        var firstBox = mediaBox
        if pageSize == "fit", let first = pages.first {
            firstBox = CGRect(x: 0, y: 0, width: first.width, height: first.height)
        }
        if firstBox == .zero { firstBox = CGRect(x: 0, y: 0, width: 595, height: 842) }

        guard let pdf = CGContext(consumer: consumer, mediaBox: &firstBox,
                                  metadata as CFDictionary) else {
            throw ProcessError.failed(code: 0, message: L("ui.could_not_create_the_pdf_context"))
        }

        for (index, image) in pages.enumerated() {
            try context.checkCancelled()

            var box: CGRect
            if pageSize == "fit" {
                box = CGRect(x: 0, y: 0, width: image.width, height: image.height)
            } else {
                box = mediaBox
                let isLandscapeImage = image.width > image.height
                let wantLandscape = orientation == "landscape"
                    || (orientation == "auto" && isLandscapeImage)
                if wantLandscape && box.height > box.width {
                    box = CGRect(x: 0, y: 0, width: box.height, height: box.width)
                }
            }

            pdf.beginPDFPage([kCGPDFContextMediaBox: box] as CFDictionary)

            if pageSize == "fit" {
                pdf.draw(image, in: box)
            } else {
                let content = box.insetBy(dx: margin, dy: margin)
                let imageAspect = CGFloat(image.width) / CGFloat(image.height)
                let contentAspect = content.width / content.height

                var drawRect: CGRect
                switch fit {
                case "stretch":
                    drawRect = content
                case "cover":
                    if imageAspect > contentAspect {
                        let height = content.height
                        let width = height * imageAspect
                        drawRect = CGRect(x: content.midX - width / 2, y: content.minY,
                                          width: width, height: height)
                    } else {
                        let width = content.width
                        let height = width / imageAspect
                        drawRect = CGRect(x: content.minX, y: content.midY - height / 2,
                                          width: width, height: height)
                    }
                    pdf.saveGState()
                    pdf.clip(to: content)
                default:
                    if imageAspect > contentAspect {
                        let width = content.width
                        let height = width / imageAspect
                        drawRect = CGRect(x: content.minX, y: content.midY - height / 2,
                                          width: width, height: height)
                    } else {
                        let height = content.height
                        let width = height * imageAspect
                        drawRect = CGRect(x: content.midX - width / 2, y: content.minY,
                                          width: width, height: height)
                    }
                }
                pdf.draw(image, in: drawRect)
                if fit == "cover" { pdf.restoreGState() }
            }

            pdf.endPDFPage()
            context.progress.report(0.4 + 0.6 * Double(index + 1) / Double(pages.count))
        }
        pdf.closePDF()
    }
}

// MARK: - 2. PDF to images

enum PDFToImageTool {
    static var tool: Tool { Tool(
        id: "pdf.toimage",
        name: L("pdf.toimage.name"),
        summary: L("pdf.toimage.summary"),
        symbol: "doc.text.image",
        category: .image,
        accepts: ["pdf"],
        actionTitle: L("pdf.toimage.action"),
        parameters: [
            .slider("dpi", L("pdf.toimage.param.dpi.label"), default: 150, min: 36, max: 600, step: 6,
                    hint: L("pdf.toimage.param.dpi.hint")),
            .picker("format", L("pdf.toimage.param.format.label"), default: "png", options: [
                .init("png", "PNG"), .init("jpeg", "JPEG"), .init("webp", "WebP"), .init("tiff", "TIFF"),
            ]),
            .slider("quality", L("pdf.toimage.param.quality.label"), default: 90, min: 40, max: 100, step: 1,
                    visibleWhen: .oneOf("format", ["jpeg", "webp"])),
            .number("startPage", L("doc.pdfsplit.param.startPage.label"), default: 1, min: 1, max: 10_000, step: 1),
            .number("endPage", L("pdf.toimage.param.endPage.label"), default: 0, min: 0, max: 10_000, step: 1),
            .toggle("transparent", L("pdf.toimage.param.transparent.label"), default: false,
                    visibleWhen: .equals("format", "png")),
        ],
        run: { context in
            var outputs: [URL] = []
            let format = ImageCodec(rawValue: context.choice("format", "png")) ?? .png
            let dpi = context.double("dpi", 150)
            let quality = context.double("quality", 90) / 100

            for (index, url) in context.inputs.enumerated() {
                try context.checkCancelled()
                guard let document = PDFDocument(url: url) else {
                    throw ProcessError.failed(code: 0, message: L("ui.could_not_open_the_pdf_url_lastpathcompone", url.lastPathComponent))
                }
                let pageCount = document.pageCount
                guard pageCount > 0 else { continue }

                let start = max(context.int("startPage", 1), 1)
                let requestedEnd = context.int("endPage", 0)
                let end = requestedEnd > 0 ? min(requestedEnd, pageCount) : pageCount
                guard start <= end else {
                    throw ProcessError.failed(code: 0, message: L("pdf.toimage.param.transparent.label.2"))
                }

                let base = url.deletingPathExtension().lastPathComponent
                let scale = dpi / 72.0

                for pageIndex in (start - 1)..<end {
                    try context.checkCancelled()
                    guard let page = document.page(at: pageIndex) else { continue }
                    let bounds = page.bounds(for: .mediaBox)
                    let width = Int(bounds.width * scale)
                    let height = Int(bounds.height * scale)
                    guard width > 0, height > 0 else { continue }

                    let colorSpace = CGColorSpaceCreateDeviceRGB()
                    let alphaInfo: CGImageAlphaInfo = context.bool("transparent") && format == .png
                        ? .premultipliedLast : .noneSkipLast
                    guard let cgContext = CGContext(
                        data: nil, width: width, height: height,
                        bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
                        bitmapInfo: alphaInfo.rawValue
                    ) else { continue }

                    cgContext.interpolationQuality = .high
                    if alphaInfo == .noneSkipLast {
                        cgContext.setFillColor(NSColor.white.cgColor)
                        cgContext.fill(CGRect(x: 0, y: 0, width: width, height: height))
                    }
                    cgContext.scaleBy(x: scale, y: scale)
                    cgContext.translateBy(x: -bounds.minX, y: -bounds.minY)
                    page.draw(with: .mediaBox, to: cgContext)

                    guard let image = cgContext.makeImage() else { continue }
                    let output = context.outputDirectory.appendingPathComponent(
                        "\(base)_\(String(format: "%03d", pageIndex + 1)).\(format.fileExtension)")

                    if ImageSupport.needsFFmpeg(format) {
                        try await ImageSupport.writeNonNative(
                            image, to: output, codec: format, quality: quality, context: context)
                    } else {
                        try ImageSupport.write(image, to: output, codec: format, quality: quality)
                    }
                    outputs.append(output)

                    let done = Double(pageIndex - start + 2) / Double(end - start + 1)
                    context.progress.report((Double(index) + done) / Double(context.inputs.count))
                }
            }
            return VideoSupport.summarise(outputs, limit: 60)
        }
    ) }
}

// MARK: - 3. Batch rename

enum ImageRenameTool {
    static var tool: Tool { Tool(
        id: "image.rename",
        name: L("image.rename.name"),
        summary: L("image.rename.summary"),
        symbol: "textformat.abc",
        category: .utility,
        accepts: [],
        resultKind: .inPlace,
        actionTitle: L("image.rename.action"),
        actionVariants: ["dryRun=true": L("ui.preview_rename")],
        parameters: [
            .text("pattern", L("image.rename.param.pattern.label"), default: L("image.rename.param.pattern.label.2"),
                  hint: L("image.rename.param.pattern.hint")),
            .number("start", L("image.rename.param.start.label"), default: 1, min: 0, max: 1_000_000, step: 1),
            .number("padding", L("image.rename.param.padding.label"), default: 3, min: 1, max: 8, step: 1),
            .picker("case", L("image.rename.param.case.label"), default: "keep", options: [
                .init("keep", L("image.rename.param.case.label.2")), .init("lower", L("image.rename.param.case.label.3")), .init("upper", L("image.rename.param.case.label.4")),
                .init("capitalize", L("image.rename.param.case.label.5")),
            ]),
            .text("find", L("image.rename.param.find.label"), default: ""),
            .text("replace", L("image.rename.param.replace.label"), default: ""),
            .picker("sort", L("image.rename.param.sort.label"), default: "name", options: [
                .init("name", L("ui.by_name")), .init("date", L("image.rename.param.sort.label.2")), .init("size", L("image.rename.param.sort.label.3")),
            ]),
            .toggle("dryRun", L("image.rename.param.dryRun.label"), default: true,
                    hint: L("image.rename.param.dryRun.hint")),
        ],
        run: { context in
            let pattern = context.string("pattern", L("image.rename.param.dryRun.label.2"))
            let start = context.int("start", 1)
            let padding = context.int("padding", 3)
            let find = context.string("find", "")
            let replace = context.string("replace", "")
            let caseMode = context.choice("case", "keep")
            let dryRun = context.bool("dryRun", true)

            var files = context.inputs
            switch context.choice("sort", "name") {
            case "date":
                files.sort {
                    let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                    let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                    return a < b
                }
            case "size":
                files.sort { FileIO.size(of: $0) < FileIO.size(of: $1) }
            default:
                files.sort { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            }

            let formatter = DateFormatter()
            formatter.dateFormat = "yyyyMMdd"

            // Two-phase rename avoids collisions when names overlap.
            var plan: [(source: URL, destination: URL)] = []
            for (index, url) in files.enumerated() {
                try context.checkCancelled()
                let ext = url.pathExtension
                let original = url.deletingPathExtension().lastPathComponent
                var name = pattern
                    .replacingOccurrences(of: "{n}", with: String(format: "%0\(padding)d", start + index))
                    .replacingOccurrences(of: "{i}", with: "\(index + 1)")
                    .replacingOccurrences(of: "{name}", with: original)
                    .replacingOccurrences(of: "{date}", with: formatter.string(from: Date()))
                    .replacingOccurrences(of: "{ext}", with: ext)

                if !find.isEmpty {
                    name = name.replacingOccurrences(of: find, with: replace)
                }
                switch caseMode {
                case "lower": name = name.lowercased()
                case "upper": name = name.uppercased()
                case "capitalize": name = name.capitalized
                default: break
                }

                name = FileIO.sanitize(name)
                let destination = url.deletingLastPathComponent()
                    .appendingPathComponent(ext.isEmpty ? name : "\(name).\(ext)")
                plan.append((url, destination))
            }

            if dryRun {
                let preview = plan.prefix(12).map {
                    "\($0.source.lastPathComponent)  →  \($0.destination.lastPathComponent)"
                }.joined(separator: "\n")
                context.progress.note(L("image.rename.param.dryRun.label.3", preview))
                // Report the plan without touching the disk.
                return []
            }

            var renamed: [URL] = []
            for (index, entry) in plan.enumerated() {
                try context.checkCancelled()
                guard entry.source.path != entry.destination.path else {
                    renamed.append(entry.source)
                    continue
                }
                guard let target = FileIO.resolveDestination(
                    entry.destination, policy: context.settings.conflictPolicy) else { continue }
                // Stage through a temporary name so chains do not collide.
                let staging = entry.source.deletingLastPathComponent()
                    .appendingPathComponent(".ff-rename-\(UUID().uuidString)")
                try? FileManager.default.moveItem(at: entry.source, to: staging)
                try FileManager.default.moveItem(at: staging, to: target)
                renamed.append(target)
                context.progress.report(Double(index + 1) / Double(plan.count))
            }
            return renamed
        }
    ) }
}

// MARK: - 4. QR code

enum QRCodeTool {
    static var tool: Tool { Tool(
        id: "utility.qr",
        name: L("utility.qr.name"),
        summary: L("utility.qr.summary"),
        symbol: "qrcode",
        category: .utility,
        accepts: ["png", "jpg", "jpeg", "tiff", "bmp", "heic", "webp", "pdf"],
        actionTitle: L("utility.qr.action"),
        actionVariants: ["action=read": L("ui.read_qr_code")],
        parameters: [
            .picker("action", L("doc.pdfsecurity.param.action.label"), default: "generate", options: [
                .init("generate", L("utility.qr.action")), .init("read", L("ui.read_qr_code")),
            ]),
            .text("content", L("utility.qr.param.content.label"), default: "https://",
                  hint: L("utility.qr.param.content.hint"),
                  visibleWhen: .equals("action", "generate")),
            .number("size", L("utility.qr.param.size.label"), default: 512, min: 64, max: 4096, step: 32,
                    visibleWhen: .equals("action", "generate")),
            .text("foreground", L("utility.qr.param.foreground.label"), default: "#000000",
                  visibleWhen: .equals("action", "generate")),
            .text("background", L("ui.background"), default: "#FFFFFF",
                  visibleWhen: .equals("action", "generate")),
            .slider("correction", L("utility.qr.param.correction.label"), default: 2, min: 0, max: 3, step: 1,
                    hint: "0=L 7%%，1=M 15%%，2=Q 25%%，3=H 30%%。",
                    visibleWhen: .equals("action", "generate")),
        ],
        minimumInputs: 0,
        run: { context in
            if context.choice("action", "generate") == "generate" {
                let content = context.string("content", "")
                guard !content.isEmpty, content != "https://" else {
                    throw ProcessError.failed(code: 0, message: L("utility.qr.param.correction.label.2"))
                }
                guard let image = QRCodeTool.generate(
                    content: content,
                    size: context.int("size", 512),
                    foreground: ImageSupport.nsColor(from: context.string("foreground", "#000000")),
                    background: ImageSupport.nsColor(from: context.string("background", "#FFFFFF")),
                    correction: context.int("correction", 2)
                ) else {
                    throw ProcessError.failed(code: 0, message: L("utility.qr.param.correction.label.3"))
                }
                let output = context.output(ext: "png", suffix: L("utility.qr.param.correction.label.4"))
                try ImageSupport.write(image, to: output, codec: .png)
                return [output]
            }

            guard !context.inputs.isEmpty else {
                throw ProcessError.failed(code: 0, message: L("utility.qr.param.correction.label.5"))
            }
            var results: [String] = []
            for url in context.inputs {
                try context.checkCancelled()
                if let text = QRCodeTool.read(url) {
                    results.append("\(url.lastPathComponent): \(text)")
                } else {
                    results.append(L("utility.qr.param.correction.label.6", url.lastPathComponent))
                }
            }
            context.progress.note(results.joined(separator: "\n"))
            return []
        }
    ) }

    static func generate(content: String, size: Int,
                         foreground: NSColor, background: NSColor,
                         correction: Int) -> CGImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(content.utf8), forKey: "inputMessage")
        let levels = ["L", "M", "Q", "H"]
        filter.setValue(levels[min(max(correction, 0), 3)], forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }

        // Tint the QR modules, then composite over the requested background.
        guard let colored = CIFilter(name: "CIFalseColor", parameters: [
            "inputImage": output,
            "inputColor0": CIColor(color: foreground) ?? CIColor.black,
            "inputColor1": CIColor(color: background) ?? CIColor.white,
        ])?.outputImage else { return nil }

        let scale = Double(size) / colored.extent.width
        let scaled = colored.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let context = CIContext(options: [.useSoftwareRenderer: false])
        return context.createCGImage(scaled, from: scaled.extent)
    }

    static func read(_ url: URL) -> String? {
        guard let image = ImageSupport.loadOriented(url) else { return nil }
        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr, .aztec, .code128, .ean13, .pdf417, .dataMatrix]
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try? handler.perform([request])
        return request.results?.first?.payloadStringValue
    }
}

// MARK: - 5. Image info

/// Colour analysis helpers used by the image inspector.
enum ImageInfoTool {
    /// k-means-lite palette extraction over a downsampled image.
    static func dominantColors(_ url: URL, count: Int) -> [String]? {
        guard let image = ImageSupport.loadOriented(url) else { return nil }
        let width = 64, height = 64
        guard let small = ImageSupport.resize(image,
            to: CGSize(width: width, height: height), fit: .stretch) else { return nil }

        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes { buffer in
            guard let base = buffer.baseAddress,
                  let cgContext = CGContext(
                    data: base, width: width, height: height,
                    bitsPerComponent: 8, bytesPerRow: width * 4,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return }
            cgContext.draw(small, in: CGRect(x: 0, y: 0, width: width, height: height))
        }

        let palette = ColorQuantizer.quantize(pixels: pixels, colorCount: count, sampleStride: 1)
        var results: [String] = []
        for i in 0..<palette.count {
            results.append(String(format: "#%02X%02X%02X",
                                  palette.red[i], palette.green[i], palette.blue[i]))
        }
        return results
    }
}
