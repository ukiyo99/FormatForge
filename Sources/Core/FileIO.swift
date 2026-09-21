import Foundation
import AppKit

/// Filesystem helpers shared by every tool.
enum FileIO {

    static let fm = FileManager.default

    /// Resolve a non-colliding destination according to the conflict policy.
    static func resolveDestination(_ url: URL, policy: AppSettings.ConflictPolicy = .rename) -> URL? {
        if !fm.fileExists(atPath: url.path) { return url }
        switch policy {
        case .overwrite:
            return url
        case .skip:
            return nil
        case .rename:
            let dir = url.deletingLastPathComponent()
            let base = url.deletingPathExtension().lastPathComponent
            let ext = url.pathExtension
            for index in 1...9999 {
                let candidate = dir.appendingPathComponent("\(base) \(index).\(ext)")
                if !fm.fileExists(atPath: candidate.path) { return candidate }
            }
            return dir.appendingPathComponent("\(base)-\(UUID().uuidString.prefix(6)).\(ext)")
        }
    }

    /// Move a freshly written file into place, honouring the conflict policy.
    /// Returns nil when the policy says to skip an existing file.
    @discardableResult
    static func commit(_ temp: URL, to destination: URL,
                       policy: AppSettings.ConflictPolicy = .rename) throws -> URL? {
        guard let target = resolveDestination(destination, policy: policy) else {
            try? fm.removeItem(at: temp)
            return nil
        }
        try fm.createDirectory(at: target.deletingLastPathComponent(),
                               withIntermediateDirectories: true)
        if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
        try fm.moveItem(at: temp, to: target)
        return target
    }

    static func size(of url: URL) -> Int64 {
        (try? fm.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
    }

    static func ensureDirectory(_ url: URL) throws {
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
    }

    static func temporaryFile(name: String = UUID().uuidString) -> URL {
        fm.temporaryDirectory
            .appendingPathComponent("FormatForge", isDirectory: true)
            .appendingPathComponent(name)
    }

    static func makeScratchDirectory() throws -> URL {
        let url = fm.temporaryDirectory
            .appendingPathComponent("FormatForge/\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func removeQuietly(_ url: URL?) {
        guard let url else { return }
        try? fm.removeItem(at: url)
    }

    /// Remove scratch directories left behind by cancelled runs.
    static func purgeStaleScratch() {
        let root = fm.temporaryDirectory.appendingPathComponent("FormatForge", isDirectory: true)
        guard let entries = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.creationDateKey])
        else { return }
        let cutoff = Date().addingTimeInterval(-86_400)
        for entry in entries {
            let created = (try? entry.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()
            if created < cutoff { try? fm.removeItem(at: entry) }
        }
    }

    /// Strip characters that are awkward in shell arguments and filenames.
    static func sanitize(_ name: String) -> String {
        let illegal = CharacterSet(charactersIn: "/\\:*?\"<>|\n\r\t")
        let cleaned = name.components(separatedBy: illegal).joined(separator: "_")
        let trimmed = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "output" : String(trimmed.prefix(180))
    }

    static func reveal(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    /// Collect a flat list of files from a set of dropped URLs, expanding
    /// directories one level deep so users can drop a folder of images.
    static func expand(_ urls: [URL], accepted: [String]) -> [URL] {
        var files: [URL] = []
        for url in urls {
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory) else { continue }
            if isDirectory.boolValue {
                let contents = (try? fm.contentsOfDirectory(
                    at: url,
                    includingPropertiesForKeys: [.isRegularFileKey],
                    options: [.skipsHiddenFiles])) ?? []
                for child in contents.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                    let ext = child.pathExtension.lowercased()
                    if accepted.isEmpty || accepted.contains(ext) { files.append(child) }
                }
            } else {
                files.append(url)
            }
        }
        return files
    }

    /// A filename that does not collide, used for sequence exports.
    static func numbered(_ base: String, index: Int, ext: String, padding: Int = 4) -> String {
        "\(base)_\(String(format: "%0\(padding)d", index)).\(ext)"
    }
}

/// Small utility for tracking total output size for the "saved X%" readout.
struct OutputSummary: Sendable {
    var files: [URL]
    var inputBytes: Int64
    var outputBytes: Int64

    var savedFraction: Double {
        guard inputBytes > 0 else { return 0 }
        return 1 - Double(outputBytes) / Double(inputBytes)
    }
}
