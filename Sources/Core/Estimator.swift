import Foundation
import CoreGraphics

// MARK: - Estimate

/// Predicted output size and duration for the current configuration.
struct WorkEstimate: Sendable, Equatable {
    /// Expected total output bytes, or nil when it cannot be predicted.
    var outputBytes: Int64?
    /// Expected wall-clock seconds, or nil when it cannot be predicted.
    var seconds: Double?
    /// Input bytes the estimate is based on.
    var inputBytes: Int64 = 0
    /// How the number was derived, shown to the user.
    var basis: String = ""
    /// True when the value is a rough guess rather than a computed figure.
    var approximate: Bool = true

    var savingFraction: Double? {
        guard let outputBytes, inputBytes > 0 else { return nil }
        return 1 - Double(outputBytes) / Double(inputBytes)
    }

    var sizeLabel: String {
        guard let outputBytes else { return L("ui.unavailable") }
        return Format.bytes(outputBytes)
    }

    var timeLabel: String {
        guard let seconds, seconds > 0 else { return L("ui.unavailable") }
        if seconds < 1 { return L("ui.under_a_second") }
        if seconds < 60 { return L("ui.about_int_seconds_rounded_s") }
        let minutes = Int(seconds / 60)
        let remainder = Int(seconds) % 60
        if minutes < 60 { return remainder > 0 ? L("ui.about_minutes_min_remainder_s", minutes, remainder) : L("ui.about_minutes_min", minutes) }
        let hours = minutes / 60
        return L("ui.about_hours_h_minutes_60_min", hours, minutes % 60)
    }

    /// Which way the size is expected to move. Exposed as data so the UI never
    /// has to inspect the translated label to decide on a colour — doing that
    /// breaks the moment the language changes.
    enum SizeChange: Sendable {
        case smaller(percent: Int)
        case larger(percent: Int)
        case unchanged

        var isReduction: Bool {
            if case .smaller = self { return true }
            return false
        }
    }

    var sizeChange: SizeChange? {
        guard let savingFraction else { return nil }
        let percent = Int((abs(savingFraction) * 100).rounded())
        if savingFraction > 0.005 { return .smaller(percent: percent) }
        if savingFraction < -0.005 { return .larger(percent: percent) }
        return .unchanged
    }

    var savingLabel: String? {
        switch sizeChange {
        case .smaller(let percent): return L("estimate.willShrink", percent)
        case .larger(let percent): return L("estimate.willGrow", percent)
        case .unchanged: return L("estimate.aboutSame")
        case nil: return nil
        }
    }
}

/// Derives size/time estimates from media properties, codec choice and the
/// current parameter values. The models are intentionally simple — a few
/// well-chosen ratios beat a fake-precise formula — and every result is marked
/// approximate in the UI.
enum Estimator {

    // MARK: Video

    /// Bits per pixel per frame, per encoder. Derived from typical CRF output
    /// on real footage: lower CRF and slower presets need more bits for the
    /// same visual quality.
    private static func bitsPerPixel(codec: VideoCodec, crf: Double, preset: String) -> Double {
        // Reference values measured at CRF 23 / medium for 1080p30.
        let base: Double
        switch codec {
        case .h264: base = 0.085
        case .hevc: base = 0.060
        case .vp9: base = 0.055
        case .av1: base = 0.045
        case .prores: base = 3.2
        case .gif: base = 0.5
        }

        // CRF is roughly logarithmic in bitrate: every 6 steps ≈ halving.
        let reference: Double = codec == .av1 ? 30 : (codec == .hevc ? 26 : 23)
        let crfFactor = pow(2.0, (reference - crf) / 6.0)

        // Presets trade encode time for compression efficiency.
        let presetFactor: Double
        switch preset {
        case "ultrafast": presetFactor = 1.35
        case "veryfast": presetFactor = 1.20
        case "fast": presetFactor = 1.10
        case "medium": presetFactor = 1.0
        case "slow": presetFactor = 0.93
        case "slower": presetFactor = 0.88
        default: presetFactor = 1.0
        }

        // ProRes is an intra codec: CRF/preset do not apply.
        if codec == .prores { return base }

        return base * crfFactor * presetFactor
    }

    static func video(
        info: MediaInfo?,
        inputBytes: Int64,
        codec: VideoCodec,
        crf: Double,
        preset: String,
        hardware: Bool,
        audioCodec: AudioCodec,
        audioBitrate: Int,
        targetBitrateKbps: Int?,
        scaleHeight: Int?,
        duration: Double,
        frameRate: Double
    ) -> WorkEstimate {
        var estimate = WorkEstimate(inputBytes: inputBytes)
        let seconds = duration > 0 ? duration : 0
        let fps = frameRate > 0 ? frameRate : 30

        // ---- Size ----
        var videoBitsPerSecond: Double
        if let targetBitrateKbps {
            videoBitsPerSecond = Double(targetBitrateKbps) * 1000
            estimate.basis = L("ui.from_the_bitrate_you_set")
            estimate.approximate = false
        } else if codec == .prores {
            // ProRes is fixed-rate per resolution; approximate from pixels.
            let width = Double(info?.width ?? 1920)
            let height = Double(scaleHeight ?? info?.height ?? 1080)
            videoBitsPerSecond = width * height * fps * bitsPerPixel(codec: codec, crf: crf, preset: preset)
            estimate.basis = L("ui.prores_is_constant_bitrate_estimated_from")
        } else {
            let width = Double(info?.width ?? 1920)
            var height = Double(info?.height ?? 1080)
            if let scaleHeight, scaleHeight < Int(height) { height = Double(scaleHeight) }
            let bpp = bitsPerPixel(codec: codec, crf: crf, preset: preset)
            videoBitsPerSecond = width * height * fps * bpp
            estimate.basis = L("ui.from_the_codec_crf_and_resolution")
        }

        var audioBitsPerSecond: Double = 0
        switch audioCodec {
        case .none: audioBitsPerSecond = 0
        case .copy:
            // Reuse the source audio bitrate when copying.
            let total = Double(info?.bitRate ?? 0)
            let videoShare = Double(info?.hasVideo == true ? 1 : 0)
            audioBitsPerSecond = videoShare > 0 ? max(total * 0.08, 128_000) : total
            estimate.basis += L("ui.audio_is_copied_as_is")
        case .flac, .alac, .pcm:
            // Lossless audio lands near 60% of raw PCM.
            let channels = Double(max(info?.channelCount ?? 2, 1))
            let rate = Double(max(info?.sampleRate ?? 48_000, 8_000))
            let factor = audioCodec == .pcm ? 1.0 : 0.6
            audioBitsPerSecond = rate * channels * 16 * factor
        default:
            audioBitsPerSecond = Double(audioBitrate) * 1000
        }

        let totalBitsPerSecond = videoBitsPerSecond + audioBitsPerSecond
        if seconds > 0 {
            // +3% for container overhead and keyframe padding.
            let bytes = Int64(totalBitsPerSecond / 8 * seconds * 1.03)
            estimate.outputBytes = max(bytes, 1024)
        } else if inputBytes > 0 {
            // No duration: fall back to a ratio based on the bitrate change.
            let sourceBitRate = Double(info?.bitRate ?? 0)
            if sourceBitRate > 0 {
                let ratio = totalBitsPerSecond / sourceBitRate
                estimate.outputBytes = Int64(Double(inputBytes) * min(max(ratio, 0.05), 3.0))
                estimate.basis = L("ui.from_the_bitrate_ratio")
            } else {
                estimate.outputBytes = Int64(Double(inputBytes) * 0.6)
                estimate.basis = L("ui.rough_ratio_no_media_info_available")
            }
        }

        // ---- Time ----
        if seconds > 0 {
            estimate.seconds = encodeSeconds(
                codec: codec, preset: preset, hardware: hardware,
                width: info?.width ?? 1920, height: info?.height ?? 1080,
                fps: fps, duration: seconds, scaleHeight: scaleHeight)
        }
        return estimate
    }

    /// Encode time as a multiple of realtime, derived from throughput observed
    /// on Apple silicon for software encoders plus a hardware speed-up factor.
    static func encodeSeconds(
        codec: VideoCodec, preset: String, hardware: Bool,
        width: Int, height: Int, fps: Double, duration: Double,
        scaleHeight: Int? = nil
    ) -> Double {
        var effectiveHeight = Double(height)
        if let scaleHeight, Double(scaleHeight) < effectiveHeight {
            effectiveHeight = Double(scaleHeight)
        }
        // Normalise to 1080p-equivalent pixel throughput.
        let pixelFactor = (Double(width) * effectiveHeight) / (1920 * 1080)
        let frameCount = duration * fps

        // Frames per second a software encoder manages at 1080p, per codec.
        var encodeFPS: Double
        switch codec {
        case .h264: encodeFPS = 260
        case .hevc: encodeFPS = 90
        case .vp9: encodeFPS = 55
        case .av1: encodeFPS = 22
        case .prores: encodeFPS = 300
        case .gif: encodeFPS = 40
        }

        switch preset {
        case "ultrafast": encodeFPS *= 2.4
        case "veryfast": encodeFPS *= 1.7
        case "fast": encodeFPS *= 1.3
        case "medium": break
        case "slow": encodeFPS *= 0.62
        case "slower": encodeFPS *= 0.42
        default: break
        }

        if hardware, codec.hardwareEncoder != nil {
            // VideoToolbox on Apple silicon is roughly 4–8× the software path.
            encodeFPS *= 5.0
        }

        let effectiveFPS = max(encodeFPS * max(pixelFactor, 0.05), 1)
        return frameCount / effectiveFPS + 0.4   // + startup cost
    }

    // MARK: Image

    static func image(
        codec: ImageCodec,
        quality: Double,
        inputBytes: Int64,
        sourceSize: CGSize?,
        targetSize: CGSize?,
        count: Int
    ) -> WorkEstimate {
        var estimate = WorkEstimate(inputBytes: inputBytes)
        let sourcePixels = (sourceSize?.width ?? 1920) * (sourceSize?.height ?? 1080)
        let targetPixels = (targetSize?.width ?? sourceSize?.width ?? 1920)
            * (targetSize?.height ?? sourceSize?.height ?? 1080)

        // Bytes per pixel for each format at a nominal quality, then scaled.
        let baseBytesPerPixel: Double
        switch codec {
        case .jpeg: baseBytesPerPixel = 0.42
        case .heic: baseBytesPerPixel = 0.28
        case .avif: baseBytesPerPixel = 0.22
        case .webp: baseBytesPerPixel = 0.32
        case .png: baseBytesPerPixel = 1.5
        case .tiff: baseBytesPerPixel = 2.6
        case .gif: baseBytesPerPixel = 0.55
        case .bmp: baseBytesPerPixel = 3.0
        case .jp2: baseBytesPerPixel = 0.5
        case .ico, .icns: baseBytesPerPixel = 1.2
        case .pdf: baseBytesPerPixel = 0.6
        case .tga, .exr: baseBytesPerPixel = 3.0
        }

        // Lossy quality scales size roughly linearly between 40% and 100%.
        let qualityFactor: Double
        if codec.supportsQuality {
            qualityFactor = 0.25 + 0.75 * pow(min(max(quality, 0.05), 1.0), 1.6)
        } else if codec == .png {
            qualityFactor = 1.0
        } else {
            qualityFactor = 1.0
        }

        let pixels = max(targetPixels, 1)
        let perImage = pixels * baseBytesPerPixel * qualityFactor
        estimate.outputBytes = Int64(perImage * Double(max(count, 1)))
        estimate.basis = L("ui.from_the_format_quality_and_pixel_count")

        // Encoding is fast, but HEIC/AVIF are noticeably slower.
        let perImageSeconds: Double
        switch codec {
        case .avif: perImageSeconds = 0.55
        case .heic: perImageSeconds = 0.18
        case .webp: perImageSeconds = 0.12
        case .jpeg: perImageSeconds = 0.05
        case .png: perImageSeconds = 0.08
        case .tiff, .bmp, .tga, .exr: perImageSeconds = 0.06
        default: perImageSeconds = 0.08
        }
        let scaleFactor = max(targetPixels / max(sourcePixels, 1), 0.05)
        estimate.seconds = perImageSeconds * scaleFactor * Double(max(count, 1)) + 0.2
        return estimate
    }

    // MARK: GIF

    static func gif(
        width: Int, height: Int, frameCount: Int, colorCount: Int, transitionFrames: Int
    ) -> WorkEstimate {
        var estimate = WorkEstimate()
        // GIF is palettised: 1 byte per pixel plus LZW overhead, which shrinks
        // with fewer colours and with inter-frame similarity.
        let pixels = Double(width) * Double(height)
        let colorFactor = 0.35 + 0.65 * (Double(colorCount) / 256.0)
        let bytesPerFrame = pixels * 0.32 * colorFactor
        let totalFrames = max(frameCount + max(0, frameCount - 1) * transitionFrames, 1)
        estimate.outputBytes = Int64(bytesPerFrame * Double(totalFrames))
        estimate.basis = L("ui.from_the_canvas_colour_count_and_frame_cou")
        // Quantisation dominates; roughly 12 ms per megapixel per frame.
        estimate.seconds = Double(totalFrames) * pixels / 1_000_000 * 0.012 + 0.3
        return estimate
    }

    // MARK: Archive

    static func archive(inputBytes: Int64, level: Int, format: ArchiveFormat) -> WorkEstimate {
        var estimate = WorkEstimate(inputBytes: inputBytes)
        // Typical compression ratios; 7z beats zip at the same level.
        let ceiling: Double
        switch format {
        case .zip: ceiling = 0.42
        case .sevenZip: ceiling = 0.32
        case .tarGz: ceiling = 0.38
        case .tar: ceiling = 1.0
        case .tarBz2: ceiling = 0.36
        }
        let levelFactor = 1.0 - (Double(min(max(level, 0), 9)) / 9.0) * (1.0 - ceiling)
        estimate.outputBytes = Int64(Double(inputBytes) * levelFactor)
        estimate.basis = L("ui.from_the_format_and_compression_level")
        // Roughly 25 MB/s at level 5, slower at higher levels.
        let throughput = 45.0 / (1.0 + Double(level) * 0.35) * 1_000_000
        estimate.seconds = Double(inputBytes) / throughput + 0.3
        return estimate
    }

    // MARK: Document

    static func document(inputBytes: Int64, target: DocumentKind, fontSize: Double) -> WorkEstimate {
        var estimate = WorkEstimate(inputBytes: inputBytes)
        let pageBytes: Double
        switch target {
        case .pdf: pageBytes = 30_000
        case .docx: pageBytes = 22_000
        case .html: pageBytes = 12_000
        case .rtf: pageBytes = 18_000
        case .md, .txt: pageBytes = 3_000
        default: pageBytes = 20_000
        }
        // Assume the input holds roughly one page per 2.5 KB of source.
        let pages = max(Double(inputBytes) / 2_500, 1)
        estimate.outputBytes = Int64(pages * pageBytes * (fontSize > 14 ? 1.15 : 1.0))
        estimate.basis = L("ui.from_the_page_count_and_target_format")
        estimate.seconds = 0.4 + pages * 0.01
        return estimate
    }
}
