import Foundation
import Observation

/// User preferences persisted to `UserDefaults`.
@Observable
final class AppSettings: @unchecked Sendable {
    static let shared = AppSettings()

    enum OutputMode: String, CaseIterable, Identifiable {
        case alongsideInput, customFolder, askEveryTime
        var id: String { rawValue }
        var label: String {
            switch self {
            case .alongsideInput: return L("ui.next_to_originals")
            case .customFolder: return L("enum.outputmode.alongsideinput")
            case .askEveryTime: return L("enum.outputmode.alongsideinput.2")
            }
        }
    }

    enum ConflictPolicy: String, CaseIterable, Identifiable {
        case rename, overwrite, skip
        var id: String { rawValue }
        var label: String {
            switch self {
            case .rename: return L("enum.conflictpolicy.rename")
            case .overwrite: return L("enum.conflictpolicy.rename.2")
            case .skip: return L("enum.conflictpolicy.rename.3")
            }
        }
    }

    private let defaults = UserDefaults.standard

    var outputMode: OutputMode {
        didSet { defaults.set(outputMode.rawValue, forKey: "outputMode") }
    }

    var customOutputPath: String {
        didSet { defaults.set(customOutputPath, forKey: "customOutputPath") }
    }

    var conflictPolicy: ConflictPolicy {
        didSet { defaults.set(conflictPolicy.rawValue, forKey: "conflictPolicy") }
    }

    var maxConcurrency: Int {
        didSet { defaults.set(maxConcurrency, forKey: "maxConcurrency") }
    }

    /// Prefer hardware encoders when the codec allows it.
    ///
    /// Defaults to **off**: VideoToolbox is faster but produces noticeably
    /// larger files at the same visual quality, so software encoding is the
    /// better default for a format-conversion tool.
    var useHardwareAcceleration: Bool {
        didSet { defaults.set(useHardwareAcceleration, forKey: "useHardwareAcceleration") }
    }

    var revealInFinderWhenDone: Bool {
        didSet { defaults.set(revealInFinderWhenDone, forKey: "revealInFinderWhenDone") }
    }

    var playSoundWhenDone: Bool {
        didSet { defaults.set(playSoundWhenDone, forKey: "playSoundWhenDone") }
    }

    var keepMetadata: Bool {
        didSet { defaults.set(keepMetadata, forKey: "keepMetadata") }
    }

    /// Path to a user-supplied ffmpeg if the bundled lookup fails.
    var customFFmpegPath: String {
        didSet { defaults.set(customFFmpegPath, forKey: "customFFmpegPath") }
    }

    private init() {
        outputMode = OutputMode(rawValue: defaults.string(forKey: "outputMode") ?? "") ?? .alongsideInput
        customOutputPath = defaults.string(forKey: "customOutputPath") ?? ""
        conflictPolicy = ConflictPolicy(rawValue: defaults.string(forKey: "conflictPolicy") ?? "") ?? .rename
        let stored = defaults.object(forKey: "maxConcurrency") as? Int
        maxConcurrency = stored ?? min(4, max(2, ProcessInfo.processInfo.activeProcessorCount / 4))
        useHardwareAcceleration = defaults.object(forKey: "useHardwareAcceleration") as? Bool ?? false
        revealInFinderWhenDone = defaults.object(forKey: "revealInFinderWhenDone") as? Bool ?? false
        playSoundWhenDone = defaults.object(forKey: "playSoundWhenDone") as? Bool ?? false
        keepMetadata = defaults.object(forKey: "keepMetadata") as? Bool ?? true
        customFFmpegPath = defaults.string(forKey: "customFFmpegPath") ?? ""
    }

    var customOutputURL: URL? {
        guard !customOutputPath.isEmpty else { return nil }
        return URL(fileURLWithPath: customOutputPath, isDirectory: true)
    }

    /// Resolve the destination folder for a run.
    ///
    /// `explicit` is a folder the user chose for this run; when present it
    /// always wins. `askEveryTime` is handled by the UI (which prompts before
    /// calling this), so it resolves like `alongsideInput` here.
    func resolveOutputDirectory(input: URL, explicit: URL?) -> URL {
        if let explicit { return explicit }
        switch outputMode {
        case .alongsideInput, .askEveryTime:
            return input.deletingLastPathComponent()
        case .customFolder:
            // Fall back to the source folder when no folder is configured yet,
            // but surface that state in the UI rather than failing silently.
            return customOutputURL ?? input.deletingLastPathComponent()
        }
    }

    /// True when the chosen mode still needs a folder from the user.
    var needsFolderSelection: Bool {
        outputMode == .customFolder && customOutputURL == nil
    }
}
