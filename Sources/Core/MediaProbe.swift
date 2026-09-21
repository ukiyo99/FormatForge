import Foundation

/// What a file actually is.
///
/// This cannot be inferred from ffprobe streams alone: a JPEG is reported as a
/// single-frame `mjpeg` *video* stream, so a naive `videoCodec != nil` test
/// would show duration, frame rate and bitrate for a still image. The file
/// extension is the reliable signal, so it drives the classification.
enum MediaKind: String, Sendable {
    case video, audio, image, document, unknown

    var label: String {
        switch self {
        case .video: return L("ui.video")
        case .audio: return L("ui.audio")
        case .image: return L("ui.image")
        case .document: return L("enum.mediakind.video")
        case .unknown: return L("ui.file")
        }
    }
}

/// Metadata extracted by `ffprobe`, used to drive smart defaults.
struct MediaInfo: Sendable, Equatable {
    /// The real nature of the file, decided by extension.
    var kind: MediaKind = .unknown
    var duration: Double = 0
    var width: Int = 0
    var height: Int = 0
    var frameRate: Double = 0
    var videoCodec: String?
    var audioCodec: String?
    var bitRate: Int64 = 0
    var sampleRate: Int = 0
    var channelCount: Int = 0
    var rotation: Int = 0
    var frameCount: Int = 0
    var pixelFormat: String?
    var containerFormat: String = ""

    /// A still image is never presented as a video, even though ffprobe
    /// reports it as a one-frame video stream.
    var hasVideo: Bool { kind == .video }
    /// Audio-only files and images both hide the video track details.
    var hasAudio: Bool { audioCodec != nil && kind != .image }
    var hasImage: Bool { kind == .image }
    /// True when the duration/frame-rate/bitrate rows are meaningful.
    var hasTimeline: Bool { kind == .video || kind == .audio }
    var aspect: Double { height > 0 ? Double(width) / Double(height) : 16.0 / 9.0 }
    var resolution: String { width > 0 ? "\(width)×\(height)" : "—" }
}

/// Cached ffprobe front-end. Probes are cheap but repeated often while the
/// user drags sliders, so results are memoised by path + modification date.
enum MediaProbe {
    private struct Key: Hashable {
        let path: String
        let modified: Date?
    }

    private static var cache: [Key: MediaInfo] = [:]
    private static let lock = NSLock()

    static func info(for url: URL) async -> MediaInfo? {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let key = Key(path: url.path, modified: attrs?[.modificationDate] as? Date)

        if let hit = cached(key) { return hit }

        guard let info = await probe(url) else { return nil }
        store(info, for: key)
        return info
    }

    static func invalidate() {
        lock.lock()
        cache.removeAll()
        lock.unlock()
    }

    // Synchronous helpers keep the lock strictly inside a non-async scope.
    private static func cached(_ key: Key) -> MediaInfo? {
        lock.lock()
        defer { lock.unlock() }
        return cache[key]
    }

    private static func store(_ info: MediaInfo, for key: Key) {
        lock.lock()
        cache[key] = info
        lock.unlock()
    }

    private static func probe(_ url: URL) async -> MediaInfo? {
        let args = [
            "-v", "error",
            "-print_format", "json",
            "-show_format",
            "-show_streams",
            url.path,
        ]
        guard let json = try? await ProcessRunner.capture("ffprobe", args),
              let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        var info = MediaInfo()
        info.kind = Self.kind(for: url)

        if let format = root["format"] as? [String: Any] {
            info.duration = (format["duration"] as? String).flatMap(Double.init) ?? 0
            info.bitRate = (format["bit_rate"] as? String).flatMap(Int64.init) ?? 0
            info.containerFormat = (format["format_name"] as? String) ?? ""
        }

        let streams = root["streams"] as? [[String: Any]] ?? []
        for stream in streams {
            let type = stream["codec_type"] as? String
            switch type {
            case "video":
                if info.videoCodec == nil {
                    info.videoCodec = stream["codec_name"] as? String
                    info.width = stream["width"] as? Int ?? 0
                    info.height = stream["height"] as? Int ?? 0
                    info.pixelFormat = stream["pix_fmt"] as? String
                    info.frameRate = parseRate(stream["avg_frame_rate"] as? String)
                        ?? parseRate(stream["r_frame_rate"] as? String) ?? 0
                    info.frameCount = (stream["nb_frames"] as? String).flatMap(Int.init) ?? 0
                    info.rotation = rotation(from: stream)
                }
            case "audio":
                if info.audioCodec == nil {
                    info.audioCodec = stream["codec_name"] as? String
                    info.sampleRate = (stream["sample_rate"] as? String).flatMap(Int.init) ?? 0
                    info.channelCount = stream["channels"] as? Int ?? 0
                }
            default:
                break
            }
        }

        if info.duration == 0, info.frameRate > 0, info.frameCount > 0 {
            info.duration = Double(info.frameCount) / info.frameRate
        }

        // For ambiguous containers, fall back to what the streams actually hold.
        if info.kind == .unknown {
            if info.videoCodec != nil && info.audioCodec != nil {
                info.kind = .video
            } else if info.videoCodec != nil {
                // A lone video stream with no duration is a still image.
                info.kind = info.duration > 0 ? .video : .image
            } else if info.audioCodec != nil {
                info.kind = .audio
            }
        }
        return info
    }

    /// Decide the file kind from its extension. Containers that can hold
    /// either audio or video (mp4, mkv, mov) are resolved by stream presence.
    static func kind(for url: URL) -> MediaKind {
        let ext = url.pathExtension.lowercased()
        if ext.isImageExtension { return .image }
        if ext.isAudioExtension { return .audio }
        if ext.isVideoExtension { return .video }
        if ext.isDocumentExtension { return .document }
        // Ambiguous containers: let the caller's stream probe decide.
        return .unknown
    }

    private static func parseRate(_ value: String?) -> Double? {
        guard let value, !value.isEmpty else { return nil }
        if value.contains("/") {
            let parts = value.split(separator: "/")
            guard parts.count == 2,
                  let num = Double(parts[0]), let den = Double(parts[1]), den != 0
            else { return nil }
            return num / den
        }
        return Double(value)
    }

    /// Rotation may live in `tags.rotate` or in the display matrix side data.
    private static func rotation(from stream: [String: Any]) -> Int {
        if let tags = stream["tags"] as? [String: Any],
           let raw = tags["rotate"] as? String, let value = Int(raw) {
            return ((value % 360) + 360) % 360
        }
        if let side = stream["side_data_list"] as? [[String: Any]] {
            for entry in side {
                if let r = entry["rotation"] as? Double {
                    return ((Int(r) % 360) + 360) % 360
                }
            }
        }
        return 0
    }

    /// Fast duration-only lookup for tools that just need a progress denominator.
    static func duration(_ url: URL) async -> Double {
        await info(for: url)?.duration ?? 0
    }
}
