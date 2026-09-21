import Foundation
import AppKit
import CryptoKit

// MARK: - Extension classification

extension String {
    var isVideoExtension: Bool {
        ["mp4", "mov", "mkv", "avi", "webm", "flv", "wmv", "m4v", "mpg", "mpeg",
         "ts", "3gp", "ogv", "mts", "m2ts"].contains(lowercased())
    }
    var isAudioExtension: Bool {
        ["mp3", "m4a", "wav", "flac", "aac", "ogg", "opus", "aiff", "aif", "wma", "alac"].contains(lowercased())
    }
    var isImageExtension: Bool {
        ["png", "jpg", "jpeg", "gif", "webp", "tiff", "tif", "bmp", "heic", "heif",
         "avif", "ico", "icns", "svg", "psd", "tga", "jp2", "exr", "raw", "dng"].contains(lowercased())
    }
    var isDocumentExtension: Bool {
        ["pdf", "doc", "docx", "rtf", "rtfd", "odt", "txt", "md", "markdown",
         "html", "htm", "epub", "webarchive"].contains(lowercased())
    }
}

extension URL {
    var fileExtensionLower: String { pathExtension.lowercased() }
    var isDirectoryURL: Bool {
        (try? resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
    }
}

// MARK: - ProcessRunner additions

extension ProcessRunner {
    static func invalidateCache() {
        cacheLock.lock()
        cache.removeAll()
        cacheLock.unlock()
    }
}

// MARK: - Font resolution

/// `drawtext` needs a real font file; these are the ones guaranteed on macOS.
enum FontResolver {
    private static let candidates = [
        "/System/Library/Fonts/Helvetica.ttc",
        "/System/Library/Fonts/SFNSMono.ttf",
        "/System/Library/Fonts/Supplemental/Arial.ttf",
        "/System/Library/Fonts/HelveticaNeue.ttc",
        "/System/Library/Fonts/Geneva.ttf",
        "/Library/Fonts/Arial.ttf",
    ]

    static func preferredFontPath() -> String? {
        candidates.first { FileManager.default.fileExists(atPath: $0) }
    }

    /// A CJK-capable font, needed whenever watermark text may contain Chinese.
    static func cjkFontPath() -> String? {
        let cjk = [
            "/System/Library/Fonts/PingFang.ttc",
            "/System/Library/Fonts/STHeiti Light.ttc",
            "/System/Library/Fonts/Hiragino Sans GB.ttc",
            "/System/Library/Fonts/Supplemental/Songti.ttc",
        ]
        return cjk.first { FileManager.default.fileExists(atPath: $0) } ?? preferredFontPath()
    }
}

// MARK: - Hashing

enum Hashing {
    static func md5(_ url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = Insecure.MD5()
        while true {
            let chunk = try? handle.read(upToCount: 1 << 20)
            guard let chunk, !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func sha256(_ data: Data) -> Data {
        Data(SHA256.hash(data: data))
    }
}

// MARK: - Concurrency helper

/// Run an async operation over a collection with bounded concurrency.
func withBoundedConcurrency<T: Sendable>(
    _ items: [T],
    limit: Int,
    operation: @escaping @Sendable (T) async throws -> Void
) async throws {
    guard !items.isEmpty else { return }
    let effective = max(1, min(limit, items.count))
    try await withThrowingTaskGroup(of: Void.self) { group in
        var iterator = items.makeIterator()
        for _ in 0..<effective {
            guard let item = iterator.next() else { break }
            group.addTask { try await operation(item) }
        }
        while let _ = try await group.next() {
            if let item = iterator.next() {
                group.addTask { try await operation(item) }
            }
        }
    }
}
