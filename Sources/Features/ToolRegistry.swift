import Foundation
import CryptoKit

/// The single source of truth for every tool in the app.
enum ToolRegistry {

    /// Tools are built lazily and cached per language revision: their names,
    /// parameter labels and hints are translated at construction time, so a
    /// language switch must rebuild them.
    private static let lock = NSLock()
    private static var cached: [Tool] = []
    private static var cachedLanguage: Language?

    static var all: [Tool] {
        lock.lock()
        defer { lock.unlock() }
        // Compare the language itself rather than its hashValue: hashing is
        // stable within a process, but comparing the value is clearer and
        // cannot collide.
        let language = LanguageStore.shared.language
        if language != cachedLanguage || cached.isEmpty {
            cached = video + image + document + archive + utility
            cachedLanguage = language
        }
        return cached
    }

    // MARK: - Video

    private static var video: [Tool] { [
        VideoConvertTool.tool,
        VideoCompressTool.tool,
        VideoResizeTool.tool,
        VideoTrimTool.tool,
        VideoConcatTool.tool,
        VideoTransformTool.tool,
        VideoSpeedTool.tool,
        VideoWatermarkTool.tool,
        VideoScreenshotTool.tool,
        VideoFrameExportTool.tool,
        VideoToGifTool.tool,
        ImagesToVideoTool.tool,
        SlideshowTool.tool,
        AudioExtractTool.tool,
        AudioMergeTool.tool,
        VideoCoverTool.tool,
        VideoFingerprintTool.tool,
        VideoMetadataStripTool.tool,
    ] }

    // MARK: - Image

    private static var image: [Tool] { [
        ImageConvertTool.tool,
        ImageCompressTool.tool,
        ImageResizeTool.tool,
        ImageTransformTool.tool,
        MultiImageGifTool.tool,
        ImageStitchTool.tool,
        ImageWatermarkTool.tool,
        ImageDecorateTool.tool,
        ImageToPDFTool.tool,
        PDFToImageTool.tool,
    ] }

    // MARK: - Document

    private static var document: [Tool] { [
        DocumentTools.wordToPDF,
        DocumentTools.pdfToWord,
        DocumentTools.txtToWord,
        DocumentTools.wordToTXT,
        DocumentTools.wordToMD,
        DocumentTools.pdfToMD,
        DocumentTools.mdToWord,
        DocumentTools.mdToPDF,
        DocumentTools.txtToPDF,
        DocumentTools.toRTF,
        DocumentTools.toHTML,
        DocumentTools.toODT,
        PDFMergeTool.tool,
        PDFSplitTool.tool,
        PDFCompressTool.tool,
        PDFSecurityTool.tool,
        OCRTool.tool,
    ] }

    // MARK: - Archive

    private static var archive: [Tool] { [
        ArchiveCreateTool.tool,
        ArchiveExtractTool.tool,
        InspectTools.archiveInfo,
    ] }

    // MARK: - Utility

    private static var utility: [Tool] { [
        InspectTools.hash,
        HashRewriteTool.tool,
        InspectTools.imageInfo,
        ImageRenameTool.tool,
        QRCodeTool.tool,
    ] }

    static func tool(withID id: String) -> Tool? {
        all.first { $0.id == id }
    }

    /// Drop the cache so the next lookup rebuilds with the new language.
    static func invalidate() {
        lock.lock()
        cachedLanguage = nil
        cached.removeAll()
        lock.unlock()
    }
}

// MARK: - Rewrite hash

/// Changes a file's checksum without altering its payload, by appending
/// padding. Kept separate from the checksum inspector, which never writes.
enum HashRewriteTool {
    static var tool: Tool { Tool(
        id: "utility.rehash",
        name: L("utility.rehash.name"),
        summary: L("utility.rehash.summary"),
        symbol: "number.circle",
        category: .utility,
        accepts: [],
        resultKind: .files,
        actionTitle: L("utility.rehash.action"),
        parameters: [
            .picker("method", L("utility.rehash.param.method.label"), default: "append", options: [
                .init("append", L("utility.rehash.param.method.label.2"), detail: L("utility.rehash.param.method.label.3")),
                .init("copy", L("utility.rehash.param.method.label.4"), detail: L("utility.rehash.param.method.label.5")),
            ]),
            .number("paddingBytes", L("utility.rehash.param.paddingBytes.label"), default: 64, min: 1, max: 65536, step: 1,
                    hint: L("utility.rehash.param.paddingBytes.hint")),
            .toggle("verify", L("utility.rehash.param.verify.label"), default: true),
        ],
        run: { context in
            var outputs: [URL] = []
            let padding = context.int("paddingBytes", 64)
            let method = context.choice("method", "append")

            for (index, input) in context.inputs.enumerated() {
                try context.checkCancelled()
                let requested = context.output(index: index, ext: input.pathExtension, suffix: L("utility.rehash.param.verify.label.2"))
                guard let output = FileIO.resolveDestination(
                    requested, policy: context.settings.conflictPolicy) else { continue }

                var paddingBytes = [UInt8](repeating: 0, count: padding)
                for i in 0..<padding { paddingBytes[i] = UInt8.random(in: 0...255) }

                if method == "append" {
                    FileIO.removeQuietly(output)
                    try FileManager.default.copyItem(at: input, to: output)
                    guard let handle = try? FileHandle(forWritingTo: output) else {
                        throw ProcessError.failed(code: 0, message: L("utility.rehash.param.verify.label.3", output.lastPathComponent))
                    }
                    defer { try? handle.close() }
                    try handle.seekToEnd()
                    try handle.write(contentsOf: Data(paddingBytes))
                } else {
                    var data = try Data(contentsOf: input)
                    data.append(contentsOf: paddingBytes)
                    try data.write(to: output)
                }

                let before = Hashing.md5(input) ?? "?"
                let after = Hashing.md5(output) ?? "?"
                context.logger.info(L("utility.rehash.param.verify.label.4", before))
                context.logger.info(L("utility.rehash.param.verify.label.5", after))
                if context.bool("verify", true) {
                    context.logger.success(after != before ? L("utility.rehash.param.verify.label.6") : L("utility.rehash.param.verify.label.7"))
                }
                outputs.append(output)
                context.progress.report(Double(index + 1) / Double(context.inputs.count))
            }
            return outputs
        }
    ) }
}
