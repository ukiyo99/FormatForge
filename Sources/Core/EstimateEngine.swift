import Foundation
import CoreGraphics

/// Computes a `WorkEstimate` for the currently selected tool by inspecting the
/// real inputs. Runs off the main actor because probing media shells out.
enum EstimateEngine {

    struct Result: Sendable {
        var estimate: WorkEstimate?
        var mediaInfo: MediaInfo?
    }

    static func compute(
        toolID: String,
        inputs: [URL],
        values: [String: ParameterValue],
        settings: AppSettings
    ) async -> Result {
        guard let first = inputs.first else { return Result(estimate: nil, mediaInfo: nil) }

        let inputBytes = inputs.reduce(Int64(0)) { $0 + FileIO.size(of: $1) }
        let count = inputs.count

        // Tools that only inspect files have no output size or duration to
        // predict, so they get no estimate card at all.
        if let tool = ToolRegistry.tool(withID: toolID),
           !tool.writesFiles(values: values) {
            let info = await MediaProbe.info(for: first)
            return Result(estimate: nil, mediaInfo: info)
        }

        func string(_ key: String, _ fallback: String = "") -> String {
            values[key]?.stringValue.isEmpty == false ? values[key]!.stringValue : fallback
        }
        func number(_ key: String, _ fallback: Double = 0) -> Double {
            values[key]?.doubleValue ?? fallback
        }
        func bool(_ key: String, _ fallback: Bool = false) -> Bool {
            values[key]?.boolValue ?? fallback
        }

        switch toolID {

        // MARK: Video

        case "video.compress", "video.convert", "video.resize", "video.speed",
             "video.watermark", "video.concat", "video.transform", "video.strip",
             "video.fingerprint", "video.trim", "video.audio.extract", "video.audio.merge",
             "video.cover":
            let info = await MediaProbe.info(for: first)
            let codec = VideoCodec(rawValue: string("codec", "h264")) ?? .h264
            let audioCodec = AudioCodec(rawValue: string("audioCodec", "aac")) ?? .aac

            // Stream-copy operations barely change size.
            let isStreamCopy = isCopyOperation(toolID: toolID, values: values)
            if isStreamCopy {
                var estimate = WorkEstimate(inputBytes: inputBytes)
                estimate.outputBytes = Int64(Double(inputBytes) * 1.01)
                estimate.basis = L("ui.stream_copy_the_size_stays_the_same")
                estimate.approximate = false
                estimate.seconds = max((info?.duration ?? 10) * 0.02, 0.3)
                return Result(estimate: estimate, mediaInfo: info)
            }

            // Target-size mode is exact by construction.
            var targetBitrate: Int?
            if string("mode") == "size", let duration = info?.duration, duration > 0 {
                let targetMB = max(number("targetSize", 20), 0.5)
                let audioKbps = number("audioBitrate", 128)
                let totalKbps = (targetMB * 8 * 1024) / duration
                targetBitrate = max(Int(totalKbps - audioKbps), 50)
            } else if string("mode") == "bitrate" {
                targetBitrate = Int(number("videoBitrate", 2500))
            }

            var scaleHeight: Int?
            switch string("scale", "original") {
            case "custom": scaleHeight = Int(number("customHeight", 0)) > 0 ? Int(number("customHeight")) : nil
            case "original": scaleHeight = nil
            default: scaleHeight = ScalePreset(rawValue: string("scale"))?.height
            }

            let estimate = Estimator.video(
                info: info,
                inputBytes: inputBytes,
                codec: codec,
                crf: number("crf", codec.defaultCRF),
                preset: string("preset", "medium"),
                hardware: bool("hardware", settings.useHardwareAcceleration),
                audioCodec: audioCodec,
                audioBitrate: Int(number("audioBitrate", 192)),
                targetBitrateKbps: targetBitrate,
                scaleHeight: scaleHeight,
                duration: info?.duration ?? 0,
                frameRate: info?.frameRate ?? 30)
            return Result(estimate: estimate, mediaInfo: info)

        case "video.gif":
            let info = await MediaProbe.info(for: first)
            let width = Int(number("width", 480))
            let aspect = info?.aspect ?? 16.0 / 9.0
            let height = max(Int(Double(width) / max(aspect, 0.01)), 1)
            let fps = number("fps", 15)
            let clip = number("duration", 5)
            let estimate = Estimator.gif(
                width: width, height: height,
                frameCount: max(Int(clip * fps), 1),
                colorCount: Int(number("colors", 256)),
                transitionFrames: 0)
            return Result(estimate: estimate, mediaInfo: info)

        case "video.screenshot", "video.frames":
            let info = await MediaProbe.info(for: first)
            let mode = string("mode", "single")
            let format = string("format", "png")
            let codec = ImageCodec.from(extension: format) ?? .png
            let frames: Int
            switch mode {
            case "single": frames = 1
            case "count": frames = max(Int(number("count", 9)), 1)
            case "all":
                frames = max(Int((info?.duration ?? 10) * (info?.frameRate ?? 30)), 1)
            case "range":
                let span = max(number("end", 10) - number("start", 0), 0.1)
                frames = max(Int(span * (info?.frameRate ?? 30)), 1)
            default:
                let interval = max(number("interval", 5), 0.05)
                frames = max(Int((info?.duration ?? 10) / interval), 1)
            }
            var width = info?.width ?? 1920
            var height = info?.height ?? 1080
            if let target = ScalePreset(rawValue: string("scale", "original"))?.height,
               target < height {
                width = Int(Double(width) * Double(target) / Double(height))
                height = target
            }
            let estimate = Estimator.image(
                codec: codec, quality: number("quality", 92) / 100,
                inputBytes: inputBytes,
                sourceSize: CGSize(width: info?.width ?? width, height: info?.height ?? height),
                targetSize: CGSize(width: width, height: height),
                count: frames)
            return Result(estimate: estimate, mediaInfo: info)

        case "video.fromimages", "video.slideshow":
            let fps = toolID == "video.fromimages" ? number("fps", 30) : 30.0
            let perImage = number("perImage", 3)
            let seconds = toolID == "video.fromimages"
                ? Double(count) / max(fps, 1)
                : Double(count) * perImage
            var estimate = WorkEstimate(inputBytes: inputBytes)
            // Roughly 0.09 bits/pixel/frame at 1080p30 H.264 CRF 20.
            estimate.outputBytes = Int64(1920 * 1080 * 30 * 0.07 / 8 * seconds)
            estimate.basis = L("ui.from_the_output_duration_and_resolution")
            estimate.seconds = Estimator.encodeSeconds(
                codec: .h264, preset: "medium", hardware: settings.useHardwareAcceleration,
                width: 1920, height: 1080, fps: 30, duration: seconds) + Double(count) * 0.15
            return Result(estimate: estimate, mediaInfo: nil)

        // MARK: Image

        case "image.convert", "image.compress", "image.resize", "image.transform",
             "image.watermark", "image.decorate":
            guard let size = ImageSupport.size(of: first) else {
                return Result(estimate: nil, mediaInfo: nil)
            }
            var codec: ImageCodec
            let requested = string("codec", string("format", "keep"))
            if requested == "keep" {
                codec = ImageCodec.from(extension: first.pathExtension) ?? .jpeg
            } else {
                codec = ImageCodec.from(extension: requested) ?? .jpeg
            }
            if toolID == "image.compress", codec == .png, string("mode", "quality") != "percent" {
                codec = .jpeg
            }
            if toolID == "image.decorate" { codec = ImageCodec.from(extension: string("format", "png")) ?? .png }

            // Resolve the target geometry the same way the tool does.
            var target = size
            let resizeMode = string("resize", string("mode", "keep"))
            switch resizeMode {
            case "maxWidth":
                let maxWidth = number("maxWidth", 1920)
                if size.width > maxWidth { target = CGSize(width: maxWidth, height: size.height * maxWidth / size.width) }
            case "maxHeight":
                let maxHeight = number("maxHeight", 1080)
                if size.height > maxHeight { target = CGSize(width: size.width * maxHeight / size.height, height: maxHeight) }
            case "percent":
                let percent = number("percent", number("scalePercent", 50)) / 100
                target = CGSize(width: size.width * percent, height: size.height * percent)
            case "longEdge":
                let edge = number("longEdge", 1600)
                let longest = max(size.width, size.height)
                if longest > 0 {
                    let scale = edge / longest
                    target = CGSize(width: size.width * scale, height: size.height * scale)
                }
            case "exact":
                target = CGSize(width: number("width", 1920), height: number("height", 1080))
            case "width":
                let width = number("width", 1920)
                target = CGSize(width: width, height: size.height * width / max(size.width, 1))
            case "height":
                let height = number("height", 1080)
                target = CGSize(width: size.width * height / max(size.height, 1), height: height)
            default:
                break
            }

            // Target-size mode: the requested size *is* the answer.
            if toolID == "image.compress", string("mode") == "targetSize" {
                var estimate = WorkEstimate(inputBytes: inputBytes)
                estimate.outputBytes = Int64(number("targetKB", 500) * 1024) * Int64(count)
                estimate.basis = L("ui.from_the_target_size_you_set")
                estimate.approximate = false
                estimate.seconds = 0.2 + Double(count) * 0.08
                return Result(estimate: estimate, mediaInfo: nil)
            }

            let estimate = Estimator.image(
                codec: codec,
                quality: number("quality", 85) / 100,
                inputBytes: inputBytes,
                sourceSize: size,
                targetSize: target,
                count: count)
            return Result(estimate: estimate, mediaInfo: nil)

        case "image.stitch":
            var totalPixels = 0.0
            var maxWidth = 0.0
            var totalHeight = 0.0
            for url in inputs {
                guard let size = ImageSupport.size(of: url) else { continue }
                totalPixels += size.width * size.height
                maxWidth = max(maxWidth, size.width)
                totalHeight += size.height
            }
            var estimate = WorkEstimate(inputBytes: inputBytes)
            estimate.outputBytes = Int64(max(totalPixels, 1) * 1.4)
            estimate.basis = L("ui.from_the_total_pixel_count_after_stitching")
            estimate.seconds = 0.3 + totalPixels / 8_000_000
            _ = (maxWidth, totalHeight)
            return Result(estimate: estimate, mediaInfo: nil)

        case "image.topdf":
            let totalPixels = inputs.reduce(0.0) { sum, url in
                guard let size = ImageSupport.size(of: url) else { return sum }
                return sum + size.width * size.height
            }
            var estimate = WorkEstimate(inputBytes: inputBytes)
            estimate.outputBytes = Int64(max(totalPixels, 1) * 0.5) + Int64(count) * 1200
            estimate.basis = L("ui.from_the_total_pixel_count")
            estimate.seconds = 0.3 + totalPixels / 20_000_000
            return Result(estimate: estimate, mediaInfo: nil)

        case "pdf.toimage":
            let dpi = number("dpi", 150)
            let scale = dpi / 72
            let pageWidth = 595.0 * scale, pageHeight = 842.0 * scale
            let codec = ImageCodec.from(extension: string("format", "png")) ?? .png
            let estimate = Estimator.image(
                codec: codec, quality: number("quality", 90) / 100,
                inputBytes: inputBytes,
                sourceSize: CGSize(width: pageWidth, height: pageHeight),
                targetSize: CGSize(width: pageWidth, height: pageHeight),
                count: count)
            return Result(estimate: estimate, mediaInfo: nil)

        case "image.gif":
            // The GIF editor owns its own recipe; estimate from the input count.
            var estimate = WorkEstimate(inputBytes: inputBytes)
            estimate.outputBytes = Int64(Double(count) * 480 * 270 * 0.32)
            estimate.basis = L("ui.from_the_frame_count_updates_live_in_the_e")
            estimate.seconds = 0.4 + Double(count) * 0.12
            return Result(estimate: estimate, mediaInfo: nil)

        // MARK: Archive

        case "archive.create":
            let format = ArchiveFormat(rawValue: string("format", "zip")) ?? .zip
            let estimate = Estimator.archive(
                inputBytes: inputBytes, level: Int(number("level", 5)), format: format)
            return Result(estimate: estimate, mediaInfo: nil)

        case "archive.extract":
            var estimate = WorkEstimate(inputBytes: inputBytes)
            // Archives typically expand to ~2.5× their compressed size.
            estimate.outputBytes = Int64(Double(inputBytes) * 2.5)
            estimate.basis = L("ui.typical_expansion_ratio_for_archives")
            estimate.seconds = 0.5 + Double(inputBytes) / 60_000_000
            return Result(estimate: estimate, mediaInfo: nil)

        // MARK: Document

        case "doc.pdfcompress":
            var estimate = WorkEstimate(inputBytes: inputBytes)
            let dpi = number("dpi", 110)
            let quality = number("quality", 65) / 100
            // Rasterising to JPEG at the target DPI dominates the result.
            let factor = (dpi / 150.0) * (0.25 + 0.75 * quality) * 0.55
            estimate.outputBytes = Int64(Double(inputBytes) * min(max(factor, 0.06), 1.2))
            estimate.basis = L("ui.from_the_target_dpi_and_jpeg_quality")
            estimate.seconds = 0.6 + Double(inputBytes) / 3_000_000
            return Result(estimate: estimate, mediaInfo: nil)

        case "doc.word2pdf", "doc.md2pdf", "doc.txt2pdf", "doc.txt2word",
             "doc.md2word", "doc.word2md", "doc.word2txt", "doc.pdf2word",
             "doc.pdf2md", "doc.tortf", "doc.tohtml", "doc.toodt":
            let target: DocumentKind
            switch toolID {
            case "doc.word2pdf", "doc.md2pdf", "doc.txt2pdf": target = .pdf
            case "doc.pdf2word", "doc.txt2word", "doc.md2word": target = .docx
            case "doc.word2md", "doc.pdf2md": target = .md
            case "doc.word2txt": target = .txt
            case "doc.tortf": target = .rtf
            case "doc.tohtml": target = .html
            case "doc.toodt": target = .odt
            default: target = .pdf
            }
            let estimate = Estimator.document(
                inputBytes: inputBytes, target: target, fontSize: number("fontSize", 13))
            return Result(estimate: estimate, mediaInfo: nil)

        case "doc.pdfmerge", "doc.pdfsplit":
            var estimate = WorkEstimate(inputBytes: inputBytes)
            estimate.outputBytes = inputBytes
            estimate.basis = toolID == "doc.pdfmerge" ? L("ui.merged_size_is_close_to_the_sum_of_the_par") : L("ui.total_size_stays_close_to_the_original")
            estimate.seconds = 0.3 + Double(count) * 0.15
            return Result(estimate: estimate, mediaInfo: nil)

        case "doc.ocr":
            let pages = count
            var estimate = WorkEstimate(inputBytes: inputBytes)
            let output = string("output", "txt")
            let perPage = output == "pdf" ? 120_000.0 : 2_500.0
            estimate.outputBytes = Int64(Double(pages) * perPage)
            estimate.basis = L("ui.from_the_page_count_and_output_format")
            let perPageSeconds = string("level", "accurate") == "accurate" ? 0.9 : 0.3
            estimate.seconds = 0.5 + Double(pages) * perPageSeconds
            return Result(estimate: estimate, mediaInfo: nil)

        default:
            // Unknown tool: fall back to a neutral "same size" prediction.
            var estimate = WorkEstimate(inputBytes: inputBytes)
            estimate.outputBytes = inputBytes
            estimate.basis = L("ui.no_model_for_this_tool")
            estimate.seconds = 0.5
            return Result(estimate: estimate, mediaInfo: nil)
        }
    }

    /// Operations that copy the encoded stream and therefore keep the size.
    private static func isCopyOperation(toolID: String, values: [String: ParameterValue]) -> Bool {
        switch toolID {
        case "video.strip", "video.fingerprint":
            return true
        case "video.trim", "video.transform":
            return values["reencode"]?.boolValue == false
        case "video.audio.extract":
            return values["action"]?.stringValue == "remove"
        default:
            return false
        }
    }
}
