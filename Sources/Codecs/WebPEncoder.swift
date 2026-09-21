import Foundation
import CoreGraphics
import AppKit

/// WebP encoding.
///
/// macOS can *read* WebP through ImageIO but cannot *write* it, and this
/// ffmpeg build has no libwebp encoder. The WebP project's `cwebp` tool is the
/// reference encoder, so we drive it directly; it handles lossy, lossless and
/// alpha correctly and is far faster than anything we could write by hand.
///
/// Install with: `brew install webp`
enum WebPEncoder {

    enum Mode: String, Sendable {
        case lossy, lossless

        var label: String {
            switch self {
            case .lossy: return L("enum.mode.lossy")
            case .lossless: return L("enum.mode.lossy.2")
            }
        }
    }

    /// True when a WebP encoder is usable on this machine.
    static var isAvailable: Bool { ProcessRunner.exists("cwebp") }

    /// A human-readable explanation shown when WebP cannot be produced.
    static var unavailableReason: String {
        L("ui.webp_output_needs_cwebp_install_it_with_br")
    }

    /// Encode an image to WebP.
    /// - Parameters:
    ///   - quality: 0…1, only meaningful for `.lossy`.
    ///   - mode: lossy or lossless.
    @discardableResult
    static func encode(
        _ image: CGImage,
        to url: URL,
        quality: Double = 0.9,
        mode: Mode = .lossy
    ) throws -> URL {
        guard isAvailable else {
            throw ProcessError.failed(code: 0, message: unavailableReason)
        }

        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        // cwebp reads from a file, so stage a PNG (which preserves alpha).
        let scratch = try FileIO.makeScratchDirectory()
        defer { FileIO.removeQuietly(scratch) }
        let source = scratch.appendingPathComponent("source.png")
        try ImageSupport.write(image, to: source, codec: .png)

        var args = ["-quiet"]
        switch mode {
        case .lossy:
            args += ["-q", "\(Int(min(max(quality, 0), 1) * 100))"]
            // Keep transparency reasonably crisp when alpha is present.
            args += ["-alpha_q", "\(Int(min(max(quality, 0.3), 1) * 100))"]
        case .lossless:
            args += ["-lossless", "-z", "6"]
        }
        args += ["-m", "4"]
        args += [source.path, "-o", url.path]

        let status = try runSync(args)
        guard status == 0, FileManager.default.fileExists(atPath: url.path) else {
            throw ProcessError.failed(code: status, message: L("ui.webp_encoding_failed"))
        }
        return url
    }

    /// `cwebp` is short-lived and CPU bound; a blocking wait is the simplest
    /// correct way to drive it from a synchronous encode path.
    private static func runSync(_ arguments: [String]) throws -> Int32 {
        guard let path = ProcessRunner.locate("cwebp") else { return -1 }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.environment = ProcessRunner.environment
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }
}
