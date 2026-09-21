import Foundation
import AppKit
import PDFKit
import Vision

// MARK: - Universal converter factory

/// Builds the family of "any document → one format" tools, which all share
/// the same load/transform/write pipeline.
enum DocumentToolFactory {

    static let sourceExtensions = [
        "docx", "doc", "rtf", "rtfd", "odt", "txt", "md", "markdown",
        "html", "htm", "pdf", "webarchive", "csv", "json", "xml", "log",
    ]

    static func make(
        id: String,
        name: String,
        summary: String,
        symbol: String,
        target: DocumentKind,
        actionTitle: String? = nil,
        extraParameters: [ToolParameter] = [],
        transform: (@Sendable (NSAttributedString, ToolContext) -> NSAttributedString)? = nil
    ) -> Tool {
        var parameters: [ToolParameter] = [
            .slider("fontSize", L("ui.body_font_size_pt"), default: 13, min: 8, max: 24, step: 1,
                    hint: L("ui.affects_text_based_output_pdf_pagination_f")),
        ]
        parameters += extraParameters

        return Tool(
            id: id,
            name: name,
            summary: summary,
            symbol: symbol,
            category: .document,
            accepts: sourceExtensions,
            actionTitle: actionTitle,
            parameters: parameters,
            run: { context in
                let fontSize = context.double("fontSize", 13)
                var outputs: [URL] = []

                for (index, input) in context.inputs.enumerated() {
                    try context.checkCancelled()
                    context.progress.note(L("ui.reading_input_lastpathcomponent", input.lastPathComponent))
                    var attributed = try DocumentSupport.load(input, fontSize: fontSize)

                    if let transform {
                        attributed = transform(attributed, context)
                    }

                    let output = context.output(index: index, ext: target.fileExtension, suffix: "")
                    context.progress.note(L("ui.writing_target_label", target.label))
                    try DocumentSupport.write(
                        attributed, to: output, kind: target,
                        pdfPageSize: pageSize(context),
                        pdfMargin: context.double("pdfMargin", 56))
                    outputs.append(output)
                    context.progress.report(Double(index + 1) / Double(context.inputs.count))
                }
                return outputs
            }
        )
    }

    static func pageSize(_ context: ToolContext) -> CGSize {
        switch context.choice("pdfPageSize", "a4") {
        case "letter": return CGSize(width: 612, height: 792)
        case "a3": return CGSize(width: 842, height: 1191)
        case "a5": return CGSize(width: 420, height: 595)
        default: return CGSize(width: 595, height: 842)
        }
    }

    static let pdfLayoutParameters: [ToolParameter] = [
        .picker("pdfPageSize", L("ui.pdf_page_size"), default: "a4", options: [
            .init("a4", "A4"), .init("letter", "Letter"), .init("a3", "A3"), .init("a5", "A5"),
        ]),
        .number("pdfMargin", L("ui.pdf_margins_pt"), default: 56, min: 0, max: 200, step: 4),
    ]
}

// MARK: - Document tools

enum DocumentTools {

    // MARK: Word → PDF

    static var wordToPDF: Tool { DocumentToolFactory.make(
        id: "doc.word2pdf",
        name: L("doc.word2pdf.name"),
        summary: L("doc.word2pdf.summary"),
        symbol: "doc.richtext",
        target: .pdf,
        actionTitle: L("doc.word2pdf.action"),
        extraParameters: DocumentToolFactory.pdfLayoutParameters
    ) }

    // MARK: PDF → Word

    static var pdfToWord: Tool { DocumentToolFactory.make(
        id: "doc.pdf2word",
        name: L("doc.pdf2word.name"),
        summary: L("doc.pdf2word.summary"),
        symbol: "doc.badge.arrow.up",
        target: .docx,
        actionTitle: L("doc.pdf2word.action"),
    ) }

    // MARK: TXT → Word

    static var txtToWord: Tool { DocumentToolFactory.make(
        id: "doc.txt2word",
        name: L("doc.txt2word.name"),
        summary: L("doc.txt2word.summary"),
        symbol: "text.alignleft",
        target: .docx,
        actionTitle: L("doc.pdf2word.action"),
        extraParameters: [
            .toggle("smartParagraphs", L("doc.txt2word.param.smartParagraphs.label"), default: true,
                    hint: L("doc.txt2word.param.smartParagraphs.hint")),
            .toggle("detectHeadings", L("doc.txt2word.param.detectHeadings.label"), default: false,
                    hint: L("doc.txt2word.param.detectHeadings.hint")),
        ],
        transform: { attributed, context in
            DocumentTools.enhancePlainText(attributed, context: context)
        }
    ) }

    // MARK: Word → TXT

    static var wordToTXT: Tool { DocumentToolFactory.make(
        id: "doc.word2txt",
        name: L("doc.word2txt.name"),
        summary: L("doc.word2txt.summary"),
        symbol: "textformat",
        target: .txt,
        actionTitle: L("doc.word2txt.action"),
        extraParameters: [
            .toggle("keepLineBreaks", L("doc.word2txt.param.keepLineBreaks.label"), default: true),
        ],
        transform: { attributed, context in
            guard !context.bool("keepLineBreaks", true) else { return attributed }
            let flattened = attributed.string
                .replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "  ", with: " ")
            return NSAttributedString(string: flattened, attributes: [
                .font: NSFont.systemFont(ofSize: context.double("fontSize", 13)),
            ])
        }
    ) }

    // MARK: Word → Markdown

    static var wordToMD: Tool { DocumentToolFactory.make(
        id: "doc.word2md",
        name: L("doc.word2md.name"),
        summary: L("doc.word2md.summary"),
        symbol: "number.square",
        target: .md,
        actionTitle: L("doc.word2md.action"),
    ) }

    // MARK: PDF → Markdown

    static var pdfToMD: Tool { DocumentToolFactory.make(
        id: "doc.pdf2md",
        name: L("doc.pdf2md.name"),
        summary: L("doc.pdf2md.summary"),
        symbol: "doc.plaintext",
        target: .md,
        actionTitle: L("doc.word2md.action"),
    ) }

    // MARK: Markdown → Word

    static var mdToWord: Tool { DocumentToolFactory.make(
        id: "doc.md2word",
        name: L("doc.md2word.name"),
        summary: L("doc.md2word.summary"),
        symbol: "text.badge.plus",
        target: .docx,
        actionTitle: L("doc.pdf2word.action"),
    ) }

    // MARK: Markdown → PDF

    static var mdToPDF: Tool { DocumentToolFactory.make(
        id: "doc.md2pdf",
        name: L("doc.md2pdf.name"),
        summary: L("doc.md2pdf.summary"),
        symbol: "doc.text.fill",
        target: .pdf,
        actionTitle: L("doc.word2pdf.action"),
        extraParameters: DocumentToolFactory.pdfLayoutParameters
    ) }

    // MARK: TXT → PDF

    static var txtToPDF: Tool { DocumentToolFactory.make(
        id: "doc.txt2pdf",
        name: L("doc.txt2pdf.name"),
        summary: L("doc.txt2pdf.summary"),
        symbol: "doc.append",
        target: .pdf,
        actionTitle: L("doc.word2pdf.action"),
        extraParameters: DocumentToolFactory.pdfLayoutParameters
    ) }

    // MARK: RTF / HTML

    static var toRTF: Tool { DocumentToolFactory.make(
        id: "doc.tortf",
        name: L("doc.tortf.name"),
        summary: L("doc.tortf.summary"),
        symbol: "doc.plaintext.fill",
        target: .rtf,
        actionTitle: L("doc.tortf.action"),
    ) }

    static var toHTML: Tool { DocumentToolFactory.make(
        id: "doc.tohtml",
        name: L("doc.tohtml.name"),
        summary: L("doc.tohtml.summary"),
        symbol: "chevron.left.forwardslash.chevron.right",
        target: .html,
        actionTitle: L("doc.tohtml.action"),
    ) }

    static var toODT: Tool { DocumentToolFactory.make(
        id: "doc.toodt",
        name: L("doc.toodt.name"),
        summary: L("doc.toodt.summary"),
        symbol: "doc.circle",
        target: .odt,
        actionTitle: L("doc.toodt.action"),
    ) }

    // MARK: Helpers

    /// Reflow plain text into proper paragraphs and optionally style headings.
    static func enhancePlainText(_ attributed: NSAttributedString, context: ToolContext) -> NSAttributedString {
        let fontSize = context.double("fontSize", 13)
        let raw = attributed.string
        let lines = raw.components(separatedBy: .newlines)
        let mergeParagraphs = context.bool("smartParagraphs", true)
        let detectHeadings = context.bool("detectHeadings", false)

        let bodyFont = NSFont.systemFont(ofSize: fontSize)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 3
        paragraph.paragraphSpacing = 8

        let result = NSMutableAttributedString()

        if !mergeParagraphs {
            result.append(NSAttributedString(string: raw, attributes: [
                .font: bodyFont, .paragraphStyle: paragraph,
            ]))
            return result
        }

        var buffer: [String] = []
        func flush() {
            guard !buffer.isEmpty else { return }
            let text = buffer.joined(separator: " ")
            result.append(NSAttributedString(string: text + "\n", attributes: [
                .font: bodyFont, .paragraphStyle: paragraph,
            ]))
            buffer.removeAll()
        }

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty {
                flush()
                result.append(NSAttributedString(string: "\n", attributes: [.font: bodyFont]))
                continue
            }

            if detectHeadings {
                let isHeading = (trimmed.hasPrefix("#") && trimmed.count < 80)
                    || (trimmed.count < 40
                        && trimmed == trimmed.uppercased()
                        && trimmed.rangeOfCharacter(from: .letters) != nil
                        && !trimmed.hasSuffix("。") && !trimmed.hasSuffix("."))
                if isHeading {
                    flush()
                    let title = trimmed.hasPrefix("#")
                        ? trimmed.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)
                        : trimmed
                    let headingParagraph = NSMutableParagraphStyle()
                    headingParagraph.paragraphSpacing = 6
                    headingParagraph.paragraphSpacingBefore = 10
                    result.append(NSAttributedString(string: title + "\n", attributes: [
                        .font: NSFont.boldSystemFont(ofSize: fontSize + 5),
                        .paragraphStyle: headingParagraph,
                    ]))
                    continue
                }
            }

            buffer.append(trimmed)
        }
        flush()
        return result
    }
}

// MARK: - PDF merge

enum PDFMergeTool {
    static var tool: Tool { Tool(
        id: "doc.pdfmerge",
        name: L("doc.pdfmerge.name"),
        summary: L("doc.pdfmerge.summary"),
        symbol: "doc.on.doc",
        category: .document,
        accepts: ["pdf"],
        actionTitle: L("doc.pdfmerge.action"),
        parameters: [
            .text("title", L("doc.pdfmerge.param.title.label"), default: L("doc.pdfmerge.param.title.label.2")),
            .toggle("addBookmarks", L("doc.pdfmerge.param.addBookmarks.label"), default: true),
        ],
        minimumInputs: 2,
        run: { context in
            let merged = PDFDocument()
            var pageIndex = 0
            var bookmarkRoot: PDFOutline?

            if context.bool("addBookmarks", true) {
                bookmarkRoot = PDFOutline()
            }

            for input in context.inputs {
                try context.checkCancelled()
                guard let document = PDFDocument(url: input) else {
                    throw ProcessError.failed(code: 0, message: L("doc.pdfmerge.param.addBookmarks.label.2", input.lastPathComponent))
                }
                let firstPageIndex = pageIndex
                for index in 0..<document.pageCount {
                    guard let page = document.page(at: index) else { continue }
                    merged.insert(page, at: pageIndex)
                    pageIndex += 1
                }

                if let root = bookmarkRoot {
                    let node = PDFOutline()
                    node.label = input.deletingPathExtension().lastPathComponent
                    if let destination = merged.page(at: firstPageIndex) {
                        node.destination = PDFDestination(page: destination, at: NSPoint(x: 0, y: 0))
                    }
                    root.insertChild(node, at: root.numberOfChildren)
                }
                context.progress.report(Double(context.inputs.firstIndex(of: input)! + 1) / Double(context.inputs.count))
            }

            guard merged.pageCount > 0 else {
                throw ProcessError.failed(code: 0, message: L("doc.pdfmerge.param.addBookmarks.label.3"))
            }
            if let root = bookmarkRoot { merged.outlineRoot = root }

            let name = FileIO.sanitize(context.string("title", L("doc.pdfmerge.param.title.label.2")))
            let output = context.output("\(name).pdf")
            guard merged.write(to: output) else {
                throw ProcessError.failed(code: 0, message: L("doc.pdfmerge.param.addBookmarks.label.4"))
            }
            return [output]
        }
    ) }
}

// MARK: - PDF split

enum PDFSplitTool {
    static var tool: Tool { Tool(
        id: "doc.pdfsplit",
        name: L("doc.pdfsplit.name"),
        summary: L("doc.pdfsplit.summary"),
        symbol: "scissors.badge.ellipsis",
        category: .document,
        accepts: ["pdf"],
        actionTitle: L("doc.pdfsplit.action"),
        parameters: [
            .picker("mode", L("doc.pdfsplit.param.mode.label"), default: "every", options: [
                .init("every", L("doc.pdfsplit.param.mode.label.2")), .init("range", L("doc.pdfsplit.param.mode.label.3")),
                .init("each", L("doc.pdfsplit.param.mode.label.4")),
            ]),
            .number("pagesPerFile", L("doc.pdfsplit.param.pagesPerFile.label"), default: 1, min: 1, max: 5000, step: 1,
                    visibleWhen: .equals("mode", "every")),
            .number("startPage", L("doc.pdfsplit.param.startPage.label"), default: 1, min: 1, max: 100_000, step: 1,
                    visibleWhen: .equals("mode", "range")),
            .number("endPage", L("doc.pdfsplit.param.endPage.label"), default: 1, min: 1, max: 100_000, step: 1,
                    visibleWhen: .equals("mode", "range")),
        ],
        run: { context in
            var outputs: [URL] = []

            for (fileIndex, input) in context.inputs.enumerated() {
                try context.checkCancelled()
                guard let document = PDFDocument(url: input) else {
                    throw ProcessError.failed(code: 0, message: L("doc.pdfmerge.param.addBookmarks.label.2", input.lastPathComponent))
                }
                let total = document.pageCount
                guard total > 0 else { continue }
                let base = input.deletingPathExtension().lastPathComponent
                let mode = context.choice("mode", "every")

                if mode == "range" {
                    let start = max(context.int("startPage", 1), 1)
                    let end = min(context.int("endPage", 1), total)
                    guard start <= end else {
                        throw ProcessError.failed(code: 0, message: L("doc.pdfsplit.param.endPage.label.2", total))
                    }
                    let part = PDFDocument()
                    for pageIndex in (start - 1)..<end {
                        if let page = document.page(at: pageIndex) {
                            part.insert(page, at: part.pageCount)
                        }
                    }
                    let output = context.output("\(base)_\(start)-\(end).pdf")
                    guard part.write(to: output) else {
                        throw ProcessError.failed(code: 0, message: L("doc.pdfsplit.param.endPage.label.3"))
                    }
                    outputs.append(output)
                    continue
                }

                let chunkSize = mode == "each" ? 1 : max(context.int("pagesPerFile", 1), 1)
                var partNumber = 1
                var pageIndex = 0
                while pageIndex < total {
                    try context.checkCancelled()
                    let part = PDFDocument()
                    let end = min(pageIndex + chunkSize, total)
                    for index in pageIndex..<end {
                        if let page = document.page(at: index) {
                            part.insert(page, at: part.pageCount)
                        }
                    }
                    let output = context.output(L("doc.pdfsplit.param.endPage.label.4", base, partNumber))
                    guard part.write(to: output) else {
                        throw ProcessError.failed(code: 0, message: L("doc.pdfsplit.param.endPage.label.3"))
                    }
                    outputs.append(output)
                    pageIndex = end
                    partNumber += 1
                    context.progress.report(Double(pageIndex) / Double(total))
                }
                _ = fileIndex
            }
            return VideoSupport.summarise(outputs, limit: 60)
        }
    ) }
}

// MARK: - PDF encrypt / decrypt

enum PDFSecurityTool {
    static var tool: Tool { Tool(
        id: "doc.pdfsecurity",
        name: L("doc.pdfsecurity.name"),
        summary: L("doc.pdfsecurity.summary"),
        symbol: "lock.doc",
        category: .document,
        accepts: ["pdf"],
        actionTitle: L("doc.pdfsecurity.action"),
        actionVariants: ["action=decrypt": L("ui.remove_password")],
        parameters: [
            .picker("action", L("doc.pdfsecurity.param.action.label"), default: "encrypt", options: [
                .init("encrypt", L("doc.pdfsecurity.param.action.label.2")), .init("decrypt", L("ui.remove_password")),
            ]),
            .text("password", L("doc.pdfsecurity.param.password.label"), default: "",
                  hint: L("doc.pdfsecurity.param.password.hint")),
            .text("ownerPassword", L("doc.pdfsecurity.param.ownerPassword.label"), default: "",
                  visibleWhen: .equals("action", "encrypt")),
            .toggle("allowPrinting", L("doc.pdfsecurity.param.allowPrinting.label"), default: true,
                    visibleWhen: .equals("action", "encrypt")),
            .toggle("allowCopying", L("doc.pdfsecurity.param.allowCopying.label"), default: false,
                    visibleWhen: .equals("action", "encrypt")),
            .picker("encryption", L("doc.pdfsecurity.param.encryption.label"), default: "aes256", options: [
                .init("aes256", L("doc.pdfsecurity.param.encryption.label.2")), .init("aes128", "AES-128"),
                .init("rc4", L("doc.pdfsecurity.param.encryption.label.3")),
            ], visibleWhen: .equals("action", "encrypt")),
        ],
        run: { context in
            var outputs: [URL] = []
            let password = context.string("password", "")

            for (index, input) in context.inputs.enumerated() {
                try context.checkCancelled()
                guard let document = PDFDocument(url: input) else {
                    throw ProcessError.failed(code: 0, message: L("doc.pdfmerge.param.addBookmarks.label.2", input.lastPathComponent))
                }

                if context.choice("action", "encrypt") == "decrypt" {
                    guard document.isEncrypted else {
                        throw ProcessError.failed(code: 0, message: L("doc.pdfsecurity.param.encryption.label.4", input.lastPathComponent))
                    }
                    guard document.unlock(withPassword: password) else {
                        throw ProcessError.failed(code: 0, message: L("doc.pdfsecurity.param.encryption.label.5", input.lastPathComponent))
                    }
                    // Avoid stacking suffixes such as "x_加密_解密".
                    let stem = input.deletingPathExtension().lastPathComponent
                    // Strip the encryption suffix if present. Its length varies
                    // by language, so measure it rather than assuming 3.
                    let encryptionSuffix = L("doc.pdfsecurity.param.encryption.label.6")
                    let base = stem.hasSuffix(encryptionSuffix)
                        ? String(stem.dropLast(encryptionSuffix.count))
                        : stem
                    let output = context.output(L("doc.pdfsecurity.param.encryption.label.7", base))
                    document.write(to: output)
                    outputs.append(output)
                    continue
                }

                guard !password.isEmpty else {
                    throw ProcessError.failed(code: 0, message: L("doc.pdfsecurity.param.encryption.label.8"))
                }
                let owner = context.string("ownerPassword", "").isEmpty
                    ? password : context.string("ownerPassword", "")

                var options: [PDFDocumentWriteOption: Any] = [
                    .userPasswordOption: password,
                    .ownerPasswordOption: owner,
                ]
                // PDFKit always applies AES-256 here; the picker only
                // documents intent, so no key-strength option is set.
                _ = context.choice("encryption", "aes256")

                var bits: UInt = 0
                if context.bool("allowPrinting", true) {
                    bits |= PDFAccessPermissions.allowsHighQualityPrinting.rawValue
                }
                if context.bool("allowCopying") {
                    bits |= PDFAccessPermissions.allowsContentCopying.rawValue
                    bits |= PDFAccessPermissions.allowsContentAccessibility.rawValue
                }
                if bits == 0 { bits = PDFAccessPermissions.allowsLowQualityPrinting.rawValue }
                options[.accessPermissionsOption] = NSNumber(value: bits)

                let output = context.output(index: index, ext: "pdf", suffix: L("doc.pdfsecurity.param.encryption.label.6"))
                guard document.write(to: output, withOptions: options) else {
                    throw ProcessError.failed(code: 0, message: L("doc.pdfsecurity.param.encryption.label.9"))
                }
                outputs.append(output)
            }
            return outputs
        }
    ) }
}

// MARK: - OCR

enum OCRTool {
    static var tool: Tool { Tool(
        id: "doc.ocr",
        name: L("doc.ocr.name"),
        summary: L("doc.ocr.summary"),
        symbol: "text.viewfinder",
        category: .document,
        accepts: ["pdf", "png", "jpg", "jpeg", "tiff", "tif", "bmp", "heic", "webp"],
        actionTitle: L("doc.ocr.action"),
        parameters: [
            .picker("output", L("doc.ocr.param.output.label"), default: "txt", options: [
                .init("txt", L("enum.document.docx")),
                .init("pdf", L("doc.ocr.param.output.label.2")),
                .init("md", "Markdown"),
            ]),
            .picker("language", L("doc.ocr.param.language.label"), default: "zh-Hans", options: [
                .init("zh-Hans", L("doc.ocr.param.language.label.2")), .init("zh-Hant", L("doc.ocr.param.language.label.3")),
                .init("en-US", L("doc.ocr.param.language.label.4")), .init("ja-JP", L("doc.ocr.param.language.label.5")), .init("ko-KR", L("doc.ocr.param.language.label.6")),
            ]),
            .picker("level", L("doc.ocr.param.level.label"), default: "accurate", options: [
                .init("accurate", L("doc.ocr.param.level.label.2")), .init("fast", L("doc.ocr.param.level.label.3")),
            ]),
            .slider("dpi", L("doc.ocr.param.dpi.label"), default: 200, min: 72, max: 600, step: 12,
                    hint: L("doc.ocr.param.dpi.hint")),
        ],
        run: { context in
            var outputs: [URL] = []
            let outputFormat = context.choice("output", "txt")
            let language = context.choice("language", "zh-Hans")
            let level = context.choice("level", "accurate")

            for (index, input) in context.inputs.enumerated() {
                try context.checkCancelled()
                let pages = try OCRTool.rasterise(input, context: context)
                guard !pages.isEmpty else {
                    throw ProcessError.failed(code: 0, message: L("doc.ocr.param.dpi.label.2", input.lastPathComponent))
                }

                var pageTexts: [String] = []
                var observations: [[VNRecognizedTextObservation]] = []

                for (pageIndex, image) in pages.enumerated() {
                    try context.checkCancelled()
                    let request = VNRecognizeTextRequest()
                    request.recognitionLevel = level == "fast" ? .fast : .accurate
                    request.recognitionLanguages = [language]
                    request.usesLanguageCorrection = true

                    let handler = VNImageRequestHandler(cgImage: image, options: [:])
                    try? handler.perform([request])

                    let results = request.results ?? []
                    observations.append(results)
                    pageTexts.append(results.compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n"))
                    context.progress.report((Double(index) + Double(pageIndex + 1) / Double(pages.count))
                                            / Double(context.inputs.count))
                }

                let base = input.deletingPathExtension().lastPathComponent
                switch outputFormat {
                case "pdf":
                    let output = context.output("\(base)_OCR.pdf")
                    try OCRTool.writeSearchablePDF(
                        pages: pages, observations: observations, to: output,
                        context: context, title: base)
                    outputs.append(output)

                case "md":
                    let output = context.output("\(base)_OCR.md")
                    let markdown = pageTexts.enumerated()
                        .map { L("doc.ocr.param.dpi.label.3", $0.offset + 1, $0.element) }
                        .joined(separator: "\n\n")
                    try markdown.write(to: output, atomically: true, encoding: .utf8)
                    outputs.append(output)

                default:
                    let output = context.output("\(base)_OCR.txt")
                    try pageTexts.joined(separator: "\n\n").write(to: output, atomically: true, encoding: .utf8)
                    outputs.append(output)
                }
            }
            return outputs
        }
    ) }

    /// Render a source file into one CGImage per page.
    static func rasterise(_ url: URL, context: ToolContext) throws -> [CGImage] {
        if url.pathExtension.lowercased() == "pdf" {
            guard let document = PDFDocument(url: url) else { return [] }
            let dpi = context.double("dpi", 200)
            let scale = dpi / 72
            var images: [CGImage] = []
            for index in 0..<min(document.pageCount, 200) {
                guard let page = document.page(at: index) else { continue }
                let bounds = page.bounds(for: .mediaBox)
                let width = Int(bounds.width * scale)
                let height = Int(bounds.height * scale)
                guard width > 0, height > 0 else { continue }
                guard let cgContext = CGContext(
                    data: nil, width: width, height: height,
                    bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
                ) else { continue }
                cgContext.setFillColor(NSColor.white.cgColor)
                cgContext.fill(CGRect(x: 0, y: 0, width: width, height: height))
                cgContext.scaleBy(x: scale, y: scale)
                cgContext.translateBy(x: -bounds.minX, y: -bounds.minY)
                page.draw(with: .mediaBox, to: cgContext)
                if let image = cgContext.makeImage() { images.append(image) }
            }
            return images
        }

        if let image = ImageSupport.loadOriented(url) { return [image] }
        return []
    }

    /// Draw the page image and overlay an invisible, selectable text layer.
    static func writeSearchablePDF(
        pages: [CGImage],
        observations: [[VNRecognizedTextObservation]],
        to url: URL,
        context: ToolContext,
        title: String
    ) throws {
        var mediaBox = CGRect(x: 0, y: 0, width: 595, height: 842)
        guard let consumer = CGDataConsumer(url: url as CFURL),
              let pdf = CGContext(consumer: consumer, mediaBox: &mediaBox,
                                  [kCGPDFContextTitle: title] as CFDictionary)
        else {
            throw ProcessError.failed(code: 0, message: L("doc.ocr.param.dpi.label.4"))
        }

        for (index, image) in pages.enumerated() {
            try context.checkCancelled()
            let box = CGRect(x: 0, y: 0, width: image.width, height: image.height)
            pdf.beginPDFPage([kCGPDFContextMediaBox: box] as CFDictionary)
            pdf.draw(image, in: box)

            // Vision returns normalised, bottom-left coordinates, which matches
            // the PDF coordinate space directly.
            pdf.setTextDrawingMode(.fill)
            for observation in observations[index] {
                guard let candidate = observation.topCandidates(1).first else { continue }
                let box = observation.boundingBox
                let fontSize = max(box.height * CGFloat(image.height) * 0.8, 4)
                let font = CTFontCreateWithName("Helvetica" as CFString, fontSize, nil)
                let attributed = NSAttributedString(string: candidate.string, attributes: [
                    .font: font,
                    .foregroundColor: NSColor.clear,
                ])
                let line = CTLineCreateWithAttributedString(attributed)
                pdf.textPosition = CGPoint(
                    x: box.minX * CGFloat(image.width),
                    y: box.minY * CGFloat(image.height))
                CTLineDraw(line, pdf)
            }
            pdf.endPDFPage()
        }
        pdf.closePDF()
    }
}

// MARK: - PDF compression

enum PDFCompressTool {
    static var tool: Tool { Tool(
        id: "doc.pdfcompress",
        name: L("doc.pdfcompress.name"),
        summary: L("doc.pdfcompress.summary"),
        symbol: "arrow.down.doc",
        category: .document,
        accepts: ["pdf"],
        actionTitle: L("archive.create.action"),
        parameters: [
            .slider("dpi", L("doc.pdfcompress.param.dpi.label"), default: 110, min: 50, max: 300, step: 10,
                    hint: L("doc.pdfcompress.param.dpi.hint")),
            .slider("quality", L("doc.pdfcompress.param.quality.label"), default: 65, min: 20, max: 95, step: 5),
            .toggle("grayscale", L("doc.pdfcompress.param.grayscale.label"), default: false),
        ],
        run: { context in
            var outputs: [URL] = []
            let dpi = context.double("dpi", 110)
            let quality = context.double("quality", 65) / 100

            for (index, input) in context.inputs.enumerated() {
                try context.checkCancelled()
                guard let document = PDFDocument(url: input) else {
                    throw ProcessError.failed(code: 0, message: L("doc.pdfmerge.param.addBookmarks.label.2", input.lastPathComponent))
                }
                let scratch = try context.makeScratch()
                defer { FileIO.removeQuietly(scratch) }

                let output = context.output(index: index, ext: "pdf", suffix: L("doc.pdfcompress.param.grayscale.label.2"))
                let scale = dpi / 150.0

                for pageIndex in 0..<document.pageCount {
                    try context.checkCancelled()
                    guard let page = document.page(at: pageIndex) else { continue }
                    let bounds = page.bounds(for: .mediaBox)
                    let width = max(Int(bounds.width * scale), 1)
                    let height = max(Int(bounds.height * scale), 1)

                    guard let cgContext = CGContext(
                        data: nil, width: width, height: height,
                        bitsPerComponent: 8, bytesPerRow: 0,
                        space: context.bool("grayscale")
                            ? CGColorSpaceCreateDeviceGray()
                            : CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
                    ) else { continue }

                    cgContext.interpolationQuality = .high
                    let fill: NSColor = context.bool("grayscale") ? .white : .white
                    cgContext.setFillColor(fill.cgColor)
                    cgContext.fill(CGRect(x: 0, y: 0, width: width, height: height))
                    cgContext.scaleBy(x: CGFloat(width) / bounds.width, y: CGFloat(height) / bounds.height)
                    cgContext.translateBy(x: -bounds.minX, y: -bounds.minY)
                    page.draw(with: .mediaBox, to: cgContext)

                    guard let rasterised = cgContext.makeImage() else { continue }
                    // Re-encode the page raster as JPEG and swap it back in.
                    let jpegURL = scratch.appendingPathComponent("page_\(pageIndex).jpg")
                    try ImageSupport.write(rasterised, to: jpegURL, codec: .jpeg, quality: quality)
                    guard let newPage = PDFPage(image: NSImage(contentsOf: jpegURL) ?? NSImage()) else { continue }
                    document.removePage(at: pageIndex)
                    document.insert(newPage, at: pageIndex)

                    context.progress.report((Double(index) + Double(pageIndex + 1) / Double(document.pageCount))
                                            / Double(context.inputs.count))
                }

                guard document.write(to: output) else {
                    throw ProcessError.failed(code: 0, message: L("doc.pdfsplit.param.endPage.label.3"))
                }
                outputs.append(output)
            }
            return outputs
        }
    ) }
}
