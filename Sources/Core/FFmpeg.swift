import Foundation

/// Codec presets and the ffmpeg argument fragments they imply.
enum VideoCodec: String, CaseIterable, Identifiable, Sendable {
    case h264, hevc, vp9, av1, prores, gif

    var id: String { rawValue }

    var label: String {
        switch self {
        case .h264: return "H.264 / AVC"
        case .hevc: return "H.265 / HEVC"
        case .vp9: return "VP9"
        case .av1: return "AV1"
        case .prores: return "Apple ProRes"
        case .gif: return "GIF"
        }
    }

    /// Short label for pickers.
    var detail: String {
        switch self {
        case .h264: return L("enum.codec.h264")
        case .hevc: return L("enum.codec.h264.2")
        case .vp9: return L("enum.codec.h264.3")
        case .av1: return L("enum.codec.h264.4")
        case .prores: return L("enum.codec.h264.5")
        case .gif: return L("enum.codec.h264.6")
        }
    }

    /// One-line summary shown under the picker.
    var summary: String {
        switch self {
        case .h264:
            return L("enum.codec.h264.7")
        case .hevc:
            return L("enum.codec.h264.8")
        case .vp9:
            return L("enum.codec.h264.9")
        case .av1:
            return L("enum.codec.h264.10")
        case .prores:
            return L("enum.codec.h264.11")
        case .gif:
            return L("enum.codec.h264.12")
        }
    }

    /// Bullet list of trade-offs, rendered in the parameter panel.
    var characteristics: [(String, String)] {
        switch self {
        case .h264:
            return [(L("enum.codec.h264.13"), L("enum.codec.h264.14")), (L("enum.codec.h264.15"), L("enum.codec.h264.16")), (L("enum.codec.h264.17"), L("enum.codec.h264.18")), (L("enum.codec.h264.19"), L("enum.codec.h264.20"))]
        case .hevc:
            return [(L("enum.codec.h264.13"), L("enum.codec.h264.21")), (L("enum.codec.h264.15"), L("enum.codec.h264.22")), (L("enum.codec.h264.17"), L("enum.codec.h264.16")), (L("enum.codec.h264.19"), L("enum.codec.h264.23"))]
        case .vp9:
            return [(L("enum.codec.h264.13"), L("enum.codec.h264.24")), (L("enum.codec.h264.15"), L("enum.codec.h264.25")), (L("enum.codec.h264.17"), L("enum.codec.h264.26")), (L("enum.codec.h264.19"), L("enum.codec.h264.27"))]
        case .av1:
            return [(L("enum.codec.h264.13"), L("enum.codec.h264.28")), (L("enum.codec.h264.15"), L("enum.codec.h264.29")), (L("enum.codec.h264.17"), L("enum.codec.h264.30")), (L("enum.codec.h264.19"), L("enum.codec.h264.31"))]
        case .prores:
            return [(L("enum.codec.h264.13"), L("enum.codec.h264.32")), (L("enum.codec.h264.15"), L("enum.codec.h264.33")), (L("enum.codec.h264.17"), L("enum.codec.h264.34")), (L("enum.codec.h264.19"), L("enum.codec.h264.35"))]
        case .gif:
            return [(L("enum.codec.h264.13"), L("enum.codec.h264.14")), (L("enum.codec.h264.15"), L("enum.codec.h264.36")), (L("enum.codec.h264.17"), L("enum.codec.h264.16")), (L("enum.codec.h264.19"), L("enum.codec.h264.37"))]
        }
    }

    /// Software encoder.
    var softwareEncoder: String {
        switch self {
        case .h264: return "libx264"
        case .hevc: return "libx265"
        case .vp9: return "libvpx-vp9"
        case .av1: return "libsvtav1"
        case .prores: return "prores_ks"
        case .gif: return "gif"
        }
    }

    /// Hardware encoder when available on Apple silicon.
    var hardwareEncoder: String? {
        switch self {
        case .h264: return "h264_videotoolbox"
        case .hevc: return "hevc_videotoolbox"
        case .prores: return "prores_videotoolbox"
        default: return nil
        }
    }

    var isCRFCapable: Bool {
        switch self {
        case .h264, .hevc, .vp9, .av1: return true
        default: return false
        }
    }

    /// Sensible CRF window per codec.
    var crfRange: ClosedRange<Double> {
        switch self {
        case .h264: return 0...51
        case .hevc: return 0...51
        case .vp9: return 0...63
        case .av1: return 0...63
        default: return 0...51
        }
    }

    var defaultCRF: Double {
        switch self {
        case .h264: return 23
        case .hevc: return 26
        case .vp9: return 32
        case .av1: return 30
        default: return 23
        }
    }

    /// Default container extension for this codec.
    var preferredExtension: String {
        switch self {
        case .h264, .hevc: return "mp4"
        case .vp9, .av1: return "webm"
        case .prores: return "mov"
        case .gif: return "gif"
        }
    }
}

/// Audio codec presets.
enum AudioCodec: String, CaseIterable, Identifiable, Sendable {
    case aac, mp3, opus, flac, alac, pcm, copy, none

    var id: String { rawValue }

    var label: String {
        switch self {
        case .aac: return "AAC"
        case .mp3: return "MP3"
        case .opus: return "Opus"
        case .flac: return L("enum.audio.aac")
        case .alac: return L("enum.audio.aac.2")
        case .pcm: return L("enum.audio.aac.3")
        case .copy: return L("enum.audio.aac.4")
        case .none: return L("enum.audio.aac.5")
        }
    }

    /// One-line explanation of the format.
    var summary: String {
        switch self {
        case .aac: return L("enum.audio.aac.6")
        case .mp3: return L("enum.audio.aac.7")
        case .opus: return L("enum.audio.aac.8")
        case .flac: return L("enum.audio.aac.9")
        case .alac: return L("enum.audio.aac.10")
        case .pcm: return L("enum.audio.aac.11")
        case .copy: return L("enum.audio.aac.12")
        case .none: return L("enum.audio.aac.13")
        }
    }

    var encoder: String? {
        switch self {
        case .aac: return "aac"
        case .mp3: return "libmp3lame"
        case .opus: return "libopus"
        case .flac: return "flac"
        case .alac: return "alac"
        case .pcm: return "pcm_s16le"
        case .copy: return "copy"
        case .none: return nil
        }
    }

    var preferredExtension: String {
        switch self {
        case .aac: return "m4a"
        case .mp3: return "mp3"
        case .opus: return "opus"
        case .flac: return "flac"
        case .alac: return "m4a"
        case .pcm: return "wav"
        case .copy, .none: return "m4a"
        }
    }
}

/// Scale presets shared by the video tools.
enum ScalePreset: String, CaseIterable, Identifiable, Sendable {
    case original, p2160, p1440, p1080, p720, p480, p360, custom

    var id: String { rawValue }

    var label: String {
        switch self {
        case .original: return L("enum.scale.original")
        case .p2160: return "4K (2160p)"
        case .p1440: return "2K (1440p)"
        case .p1080: return "1080p"
        case .p720: return "720p"
        case .p480: return "480p"
        case .p360: return "360p"
        case .custom: return L("enum.scale.original.2")
        }
    }

    /// Target height, or nil to keep the source height.
    var height: Int? {
        switch self {
        case .p2160: return 2160
        case .p1440: return 1440
        case .p1080: return 1080
        case .p720: return 720
        case .p480: return 480
        case .p360: return 360
        case .original, .custom: return nil
        }
    }
}

// MARK: - ffmpeg driver

enum FFmpeg {

    static var available: Bool { ProcessRunner.exists("ffmpeg") && ProcessRunner.exists("ffprobe") }

    /// Base flags applied to every invocation: quiet, non-interactive, overwrite.
    static var baseFlags: [String] {
        ["-hide_banner", "-nostdin", "-y", "-loglevel", "error", "-stats_period", "0.3"]
    }

    /// Build the video-encoding fragment for a codec/quality combination.
    static func videoArgs(
        codec: VideoCodec,
        quality: Double,
        hardware: Bool,
        preset: String? = nil,
        targetBitrateKbps: Int? = nil
    ) -> [String] {
        var args: [String] = []

        // GIF is handled by a dedicated palette pipeline elsewhere.
        if codec == .gif {
            return ["-c:v", "gif"]
        }

        let useHardware = hardware && codec.hardwareEncoder != nil
        let encoder = useHardware ? codec.hardwareEncoder! : codec.softwareEncoder
        args += ["-c:v", encoder]

        if useHardware {
            // VideoToolbox ignores CRF; drive it with an explicit bitrate that
            // tracks the requested quality (lower CRF => higher bitrate).
            if let targetBitrateKbps {
                args += ["-b:v", "\(targetBitrateKbps)k", "-maxrate", "\(Int(Double(targetBitrateKbps) * 1.5))k",
                         "-bufsize", "\(targetBitrateKbps * 2)k"]
            } else {
                // Map CRF onto VideoToolbox's 0-100 quality scale (higher = better).
                let range = codec.crfRange
                let normalised = 1 - (quality - range.lowerBound) / max(range.upperBound - range.lowerBound, 1)
                let q = Int((normalised * 80) + 15)
                args += ["-q:v", "\(min(max(q, 1), 100))"]
            }
            args += ["-allow_sw", "1"]
            return args
        }

        switch codec {
        case .h264:
            args += ["-crf", fmt(quality)]
            args += ["-preset", preset ?? "medium"]
            args += ["-pix_fmt", "yuv420p"]
        case .hevc:
            args += ["-crf", fmt(quality)]
            args += ["-preset", preset ?? "medium"]
            args += ["-pix_fmt", "yuv420p"]
            // Make HEVC playable in QuickTime.
            args += ["-tag:v", "hvc1"]
        case .vp9:
            // VP9 needs a bitrate ceiling alongside CRF to converge quickly.
            args += ["-crf", fmt(quality), "-b:v", "0"]
            args += ["-row-mt", "1", "-cpu-used", preset ?? "2"]
        case .av1:
            args += ["-crf", fmt(quality)]
            args += ["-preset", preset ?? "6"]
        case .prores:
            // ProRes profiles are chosen by number rather than CRF.
            args += ["-profile:v", "3"]
        case .gif:
            break
        }
        return args
    }

    static func audioArgs(codec: AudioCodec, bitrateKbps: Int = 192) -> [String] {
        guard let encoder = codec.encoder else { return ["-an"] }
        if encoder == "copy" { return ["-c:a", "copy"] }
        var args = ["-c:a", encoder]
        switch codec {
        case .aac, .mp3, .opus:
            args += ["-b:a", "\(bitrateKbps)k"]
        case .alac:
            args += ["-b:a", "\(max(bitrateKbps, 256))k"]
        default:
            break
        }
        return args
    }

    /// Resize fragment. `-2` keeps the value even, which most encoders require.
    static func scaleArgs(width: Int?, height: Int?, mode: String = "fit") -> [String] {
        guard width != nil || height != nil else { return [] }
        let w = width.map { "\($0)" } ?? "-2"
        let h = height.map { "\($0)" } ?? "-2"

        switch mode {
        case "fill":
            // Scale up to cover then crop to the exact box.
            let wExpr = width.map { "\($0)" } ?? "iw"
            let hExpr = height.map { "\($0)" } ?? "ih"
            return ["-vf", "scale=\(wExpr):\(hExpr):force_original_aspect_ratio=increase,crop=\(wExpr):\(hExpr)"]
        case "stretch":
            return ["-vf", "scale=\(w):\(h)"]
        default:
            return ["-vf", "scale=\(w):\(h):force_original_aspect_ratio=decrease"]
        }
    }

    /// Parse an ffmpeg `-progress pipe:1` stream, reporting fractional progress.
    /// `out_time_us` is microseconds; we fall back to `out_time_ms`.
    static func progressHandler(
        duration: Double,
        reporter: ProgressReporter,
        logger: JobLogger = .silent
    ) -> @Sendable (String) -> Void {
        guard duration > 0 else {
            return { line in
                if line.hasPrefix("frame=") { reporter.note(L("ui.encoding_line_dropfirst_6", line.dropFirst(6))) }
            }
        }
        // Only log progress every ~5% so the log stays readable.
        let tracker = ProgressLogTracker(duration: duration, logger: logger)
        return { line in
            let parts = line.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { return }
            let key = String(parts[0]), value = String(parts[1])
            switch key {
            case "out_time_us", "out_time_ms":
                guard let raw = Double(value) else { return }
                let seconds = raw / 1_000_000
                reporter.report(seconds / duration)
                tracker.record(seconds: seconds, speed: nil)
            case "speed":
                reporter.note(L("ui.speed_value", value))
                tracker.record(seconds: nil, speed: value)
            default:
                break
            }
        }
    }

    /// Run ffmpeg with live progress. Returns the produced output URL.
    @discardableResult
    static func execute(
        context: ToolContext,
        arguments: [String],
        duration: Double,
        output: URL,
        extraInputs: [String] = []
    ) async throws -> URL {
        guard available else { throw ProcessError.missingTool("ffmpeg") }

        try FileManager.default.createDirectory(
            at: output.deletingLastPathComponent(), withIntermediateDirectories: true)

        var args = baseFlags
        args += ["-progress", "pipe:1", "-nostats"]
        args += arguments

        context.logger.commandLines("ffmpeg", args)
        context.logger.info(L("ui.output_output_path", output.path))

        // Stream meaningful stderr into the log as it arrives so the user can
        // watch what ffmpeg is actually doing.
        let stderrSink: @Sendable (String) -> Void = { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return }
            context.logger.output(trimmed)
        }

        let handler = progressHandler(duration: duration, reporter: context.progress,
                                      logger: context.logger)
        let result = try await ProcessRunner.run(
            "ffmpeg", args, handle: context.handle,
            onStdout: handler, onStderr: stderrSink)

        if result.cancelled { throw ProcessError.cancelled }
        guard result.exitCode == 0 else {
            context.logger.error(L("ui.ffmpeg_exited_with_code_result_exitcode", result.exitCode))
            throw ProcessError.failed(code: result.exitCode, message: result.stderr)
        }
        guard FileManager.default.fileExists(atPath: output.path) else {
            throw ProcessError.failed(code: 0, message: L("ui.the_output_file_was_not_created"))
        }
        context.progress.report(1)
        return output
    }

    /// Escape a path for use inside a filtergraph option value.
    static func escapeFilterPath(_ path: String) -> String {
        path
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: ":", with: "\\:")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "[", with: "\\[")
            .replacingOccurrences(of: "]", with: "\\]")
            .replacingOccurrences(of: ",", with: "\\,")
            .replacingOccurrences(of: ";", with: "\\;")
    }

    /// Escape text for `drawtext`.
    static func escapeDrawText(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: ":", with: "\\:")
            .replacingOccurrences(of: "'", with: "\u{2019}")
            .replacingOccurrences(of: "%", with: "\\%")
    }

    private static func fmt(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.2f", value)
    }
}

/// Emits a log line every ~5% of progress, carrying the current speed.
private final class ProgressLogTracker: @unchecked Sendable {
    private let lock = NSLock()
    private let duration: Double
    private let logger: JobLogger
    private var lastBucket = -1
    private var latestSpeed: String?

    init(duration: Double, logger: JobLogger) {
        self.duration = duration
        self.logger = logger
    }

    func record(seconds: Double?, speed: String?) {
        lock.lock()
        if let speed { latestSpeed = speed }
        guard let seconds, duration > 0 else { lock.unlock(); return }
        let fraction = min(max(seconds / duration, 0), 1)
        let bucket = Int(fraction * 20)
        guard bucket > lastBucket else { lock.unlock(); return }
        lastBucket = bucket
        let speedText = latestSpeed.map { L("ui.0", $0) } ?? ""
        lock.unlock()
        logger.info(String(format: L("ui.progress_d_processed"),
                           bucket * 5,
                           Format.duration(seconds),
                           speedText))
    }
}
