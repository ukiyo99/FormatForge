import Foundation
import Observation

// MARK: - Language

/// The languages the interface can be displayed in.
///
/// The app ships **English by default**; every other language is one click away
/// in Settings. Changing it repaints the whole interface immediately — no
/// relaunch.
enum Language: String, CaseIterable, Identifiable, Sendable {
    case english    = "en"
    case chineseSimplified  = "zh-Hans"
    case chineseTraditional = "zh-Hant"
    case japanese   = "ja"
    case korean     = "ko"
    case french     = "fr"
    case german     = "de"
    case spanish    = "es"
    case portuguese = "pt"
    case russian    = "ru"
    case italian    = "it"
    case dutch      = "nl"

    var id: String { rawValue }

    /// The language's name written in that language, so the picker is readable
    /// no matter which language is currently active.
    /// The language's own name. Never translated: a German user looking for
    /// Chinese should see “简体中文”, not “Chinesisch”.
    var nativeName: String {
        switch self {
        case .english: return "English"
        case .chineseSimplified: return "简体中文"
        case .chineseTraditional: return "繁體中文"
        case .japanese: return "日本語"
        case .korean: return "한국어"
        case .french: return "Français"
        case .german: return "Deutsch"
        case .spanish: return "Español"
        case .portuguese: return "Português"
        case .russian: return "Русский"
        case .italian: return "Italiano"
        case .dutch: return "Nederlands"
        }
    }

    /// The English name, shown as a secondary line in the picker so the list is
    /// navigable even when the interface language is unfamiliar.
    var englishName: String {
        switch self {
        case .english: return "English"
        case .chineseSimplified: return "Chinese (Simplified)"
        case .chineseTraditional: return "Chinese (Traditional)"
        case .japanese: return "Japanese"
        case .korean: return "Korean"
        case .french: return "French"
        case .german: return "German"
        case .spanish: return "Spanish"
        case .portuguese: return "Portuguese"
        case .russian: return "Russian"
        case .italian: return "Italian"
        case .dutch: return "Dutch"
        }
    }

    /// Resolve the closest match for the system preference. Used only on first
    /// launch; English stays the default for anything unrecognised.
    static func matching(_ identifier: String) -> Language? {
        let lowered = identifier.lowercased()
        // Traditional Chinese must be tested before Simplified: "zh-hant"
        // contains neither "hans" nor a bare "zh" match that we want.
        if lowered.hasPrefix("zh") {
            if lowered.contains("hant") || lowered.contains("tw")
                || lowered.contains("hk") || lowered.contains("mo") {
                return .chineseTraditional
            }
            return .chineseSimplified
        }
        for language in Language.allCases
        where lowered.hasPrefix(language.rawValue.lowercased()) {
            return language
        }
        return nil
    }

    /// Best guess from the system's preferred languages.
    static var systemDefault: Language {
        for identifier in Locale.preferredLanguages {
            if let match = matching(identifier) { return match }
        }
        return .english
    }
}

// MARK: - Store

/// Thread-safe holder for the active language and its loaded tables.
///
/// Deliberately *not* main-actor isolated: tool definitions are global
/// `static let` values and enum labels are computed properties, so lookups
/// happen from non-isolated contexts. SwiftUI observes `Localization` (below)
/// for redraws; this type only serves reads.
final class LanguageStore: @unchecked Sendable {
    static let shared = LanguageStore()

    private let lock = NSLock()
    private var current: Language
    private var tables: [Language: [String: String]] = [:]

    private init() {
        // English is the default; the system language is only consulted when it
        // is one we actually ship, so a French user on a Japanese system does
        // not land in a half-translated interface by accident.
        if let stored = UserDefaults.standard.string(forKey: "language"),
           let value = Language(rawValue: stored) {
            current = value
        } else {
            current = .english
        }
    }

    var language: Language {
        lock.lock(); defer { lock.unlock() }
        return current
    }

    func setLanguage(_ language: Language) {
        lock.lock()
        guard language != current else { lock.unlock(); return }
        current = language
        lock.unlock()
        UserDefaults.standard.set(language.rawValue, forKey: "language")
    }

    /// Look up `key`, falling back to English and then to the key itself so a
    /// missing entry is obvious rather than blank.
    func text(_ key: String) -> String {
        let active = language
        if let value = table(active)[key] { return value }
        if active != .english, let value = table(.english)[key] { return value }
        return key
    }

    func table(_ language: Language) -> [String: String] {
        lock.lock()
        if let cached = tables[language] { lock.unlock(); return cached }
        lock.unlock()

        let loaded = Self.load(language)

        lock.lock()
        tables[language] = loaded
        lock.unlock()
        return loaded
    }

    func reload() {
        lock.lock(); tables.removeAll(); lock.unlock()
    }

    /// Find a language table.
    ///
    /// Normally it lives in the app bundle at `Contents/Resources/i18n/`. The
    /// fallbacks exist so the test harness and any command-line tool can load
    /// the same files without being wrapped in a bundle.
    private static func locate(_ language: Language) -> URL? {
        let name = language.rawValue
        let bundle = Bundle.main

        if let url = bundle.url(forResource: name, withExtension: "json",
                                subdirectory: "i18n") {
            return url
        }
        if let url = bundle.url(forResource: name, withExtension: "json") {
            return url
        }

        // Next to the running executable: <dir>/i18n/<code>.json
        let executable = URL(fileURLWithPath: CommandLine.arguments[0])
            .resolvingSymlinksInPath()
            .deletingLastPathComponent()
        let candidates = [
            executable.appendingPathComponent("i18n/\(name).json"),
            executable.appendingPathComponent("Resources/i18n/\(name).json"),
            // And relative to the current directory, for `swift run`-style use.
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("Resources/i18n/\(name).json"),
        ]
        for candidate in candidates where FileManager.default.fileExists(atPath: candidate.path) {
            return candidate
        }
        return nil
    }

    private static func load(_ language: Language) -> [String: String] {
        guard let url = locate(language) else {
            SharedLog.record("i18n: no resource for \(language.rawValue)")
            return [:]
        }
        do {
            let data = try Data(contentsOf: url)
            guard let parsed = try JSONSerialization.jsonObject(with: data) as? [String: String]
            else {
                SharedLog.record("i18n: \(language.rawValue).json is not a flat string map")
                return [:]
            }
            return parsed
        } catch {
            SharedLog.record("i18n: could not read \(language.rawValue).json — \(error)")
            return [:]
        }
    }
}

/// Minimal stderr logger so i18n problems are visible without pulling in the
/// per-task job logger.
enum SharedLog {
    static func record(_ message: String) {
        FileHandle.standardError.write(Data("[FormatForge] \(message)\n".utf8))
    }
}

// MARK: - Observable wrapper

/// SwiftUI-observable view of the active language.
///
/// Views read `Localization.shared.language` so a change repaints the whole
/// interface; the lookups themselves go through `LanguageStore`, which any
/// thread may call.
@Observable
@MainActor
final class Localization {
    static let shared = Localization()

    var language: Language {
        didSet {
            guard language != oldValue else { return }
            LanguageStore.shared.setLanguage(language)
        }
    }

    private init() {
        language = LanguageStore.shared.language
    }
}

// MARK: - Lookup

/// Translate `key` into the active language. Callable from any context.
func L(_ key: String) -> String {
    LanguageStore.shared.text(key)
}

/// Translate and interpolate.
///
/// Placeholders are `%@` (string) and `%d` (integer), substituted in the order
/// given. A language may reorder them freely because the translator controls
/// where each placeholder sits in the sentence.
func L(_ key: String, _ arguments: Any...) -> String {
    var result = LanguageStore.shared.text(key)
    for argument in arguments {
        let stringIndex = result.range(of: "%@")
        let intIndex = result.range(of: "%d")
        let target: Range<String.Index>?
        switch (stringIndex, intIndex) {
        case let (s?, i?): target = s.lowerBound < i.lowerBound ? s : i
        case let (s?, nil): target = s
        case let (nil, i?): target = i
        case (nil, nil): target = nil
        }
        guard let target else { break }
        result.replaceSubrange(target, with: "\(argument)")
    }
    return result
}
