import Foundation
import CryptoKit

// MARK: - Algorithms

/// Every checksum the app can compute.
enum HashAlgorithm: String, CaseIterable, Identifiable, Sendable {
    case md5, sha1, sha256, sha512, crc32

    var id: String { rawValue }

    var label: String {
        switch self {
        case .md5: return "MD5"
        case .sha1: return "SHA-1"
        case .sha256: return "SHA-256"
        case .sha512: return "SHA-512"
        case .crc32: return "CRC32"
        }
    }

    var detail: String {
        switch self {
        case .md5: return L("enum.hash.md5")
        case .sha1: return L("enum.hash.md5.2")
        case .sha256: return L("enum.hash.md5.3")
        case .sha512: return L("enum.hash.md5.4")
        case .crc32: return L("enum.hash.md5.5")
        }
    }

    var hexLength: Int {
        switch self {
        case .md5: return 32
        case .sha1: return 40
        case .sha256: return 64
        case .sha512: return 128
        case .crc32: return 8
        }
    }
}

// MARK: - CRC32

/// Table-driven CRC-32 (IEEE 802.3), matching the value `crc32` prints.
struct CRC32 {
    private static let table: [UInt32] = {
        (0..<256).map { index -> UInt32 in
            var value = UInt32(index)
            for _ in 0..<8 {
                value = (value & 1) != 0 ? (0xEDB8_8320 ^ (value >> 1)) : (value >> 1)
            }
            return value
        }
    }()

    private var crc: UInt32 = 0xFFFF_FFFF

    mutating func update(_ data: Data) {
        var value = crc
        for byte in data {
            value = Self.table[Int((value ^ UInt32(byte)) & 0xFF)] ^ (value >> 8)
        }
        crc = value
    }

    var checksum: UInt32 { crc ^ 0xFFFF_FFFF }

    var hex: String { String(format: "%08x", checksum) }
}

// MARK: - Multi-hash

/// Computes every requested checksum in a **single pass** over the file, so
/// asking for five algorithms costs one read rather than five.
enum HashEngine {

    /// Result for one file.
    struct Result: Sendable {
        var url: URL
        var values: [HashAlgorithm: String]
        var bytes: Int64
        var seconds: Double
        var error: String?

        var ok: Bool { error == nil }
    }

    /// Hash one file with all requested algorithms.
    static func hash(
        _ url: URL,
        algorithms: [HashAlgorithm] = HashAlgorithm.allCases,
        chunkSize: Int = 1 << 20,
        progress: (@Sendable (Double) -> Void)? = nil
    ) -> Result {
        let start = Date()
        let wanted = Set(algorithms)

        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return Result(url: url, values: [:], bytes: 0, seconds: 0,
                          error: L("ui.could_not_read_the_file"))
        }
        defer { try? handle.close() }

        var md5 = wanted.contains(.md5) ? Insecure.MD5() : nil
        var sha1 = wanted.contains(.sha1) ? Insecure.SHA1() : nil
        var sha256 = wanted.contains(.sha256) ? SHA256() : nil
        var sha512 = wanted.contains(.sha512) ? SHA512() : nil
        var crc = wanted.contains(.crc32) ? CRC32() : nil

        // Total size drives the progress fraction.
        let total = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: 0)

        var processed: Int64 = 0
        while true {
            guard let chunk = try? handle.read(upToCount: chunkSize), !chunk.isEmpty else { break }
            md5?.update(data: chunk)
            sha1?.update(data: chunk)
            sha256?.update(data: chunk)
            sha512?.update(data: chunk)
            crc?.update(chunk)

            processed += Int64(chunk.count)
            if total > 0 { progress?(Double(processed) / Double(total)) }
        }

        var values: [HashAlgorithm: String] = [:]
        if let md5 { values[.md5] = hex(md5.finalize()) }
        if let sha1 { values[.sha1] = hex(sha1.finalize()) }
        if let sha256 { values[.sha256] = hex(sha256.finalize()) }
        if let sha512 { values[.sha512] = hex(sha512.finalize()) }
        if let crc { values[.crc32] = crc.hex }

        return Result(url: url, values: values, bytes: processed,
                      seconds: Date().timeIntervalSince(start), error: nil)
    }

    private static func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Verify a file against an expected checksum.
    static func verify(_ url: URL, expected: String, algorithm: HashAlgorithm) -> Bool? {
        let normalized = expected.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return nil }
        let result = hash(url, algorithms: [algorithm])
        guard let actual = result.values[algorithm] else { return nil }
        return actual == normalized
    }
}
