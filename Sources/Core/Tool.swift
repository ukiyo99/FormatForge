import Foundation

// MARK: - Parameter values

enum ParameterValue: Sendable, Equatable {
    case text(String)
    case number(Double)
    case bool(Bool)
    case choice(String)

    var stringValue: String {
        switch self {
        case .text(let s): return s
        case .number(let n): return n == n.rounded() ? String(Int(n)) : String(n)
        case .bool(let b): return b ? "true" : "false"
        case .choice(let c): return c
        }
    }

    var doubleValue: Double {
        switch self {
        case .number(let n): return n
        case .text(let s): return Double(s) ?? 0
        case .bool(let b): return b ? 1 : 0
        case .choice(let c): return Double(c) ?? 0
        }
    }

    var boolValue: Bool {
        switch self {
        case .bool(let b): return b
        case .text(let s): return ["true", "1", "yes", "on"].contains(s.lowercased())
        case .number(let n): return n != 0
        case .choice(let c): return ["true", "1", "yes", "on"].contains(c.lowercased())
        }
    }
}

// MARK: - Parameter description

struct PickerOption: Identifiable, Hashable, Sendable {
    let id: String
    let label: String
    /// Extra explanation shown as a trailing hint.
    var detail: String? = nil

    init(_ id: String, _ label: String, detail: String? = nil) {
        self.id = id
        self.label = label
        self.detail = detail
    }
}

/// When a parameter should be visible in the form.
enum ParameterVisibility: Sendable {
    case always
    case equals(String, String)
    case oneOf(String, [String])
    case notEquals(String, String)
    case truthy(String)

    func isVisible(in values: [String: ParameterValue]) -> Bool {
        switch self {
        case .always:
            return true
        case .equals(let key, let expected):
            return values[key]?.stringValue == expected
        case .oneOf(let key, let expected):
            guard let v = values[key]?.stringValue else { return false }
            return expected.contains(v)
        case .notEquals(let key, let value):
            return values[key]?.stringValue != value
        case .truthy(let key):
            return values[key]?.boolValue ?? false
        }
    }
}

enum ParameterKind: Sendable {
    case text(placeholder: String)
    case number(min: Double, max: Double, step: Double)
    /// Bounded numeric control rendered as a slider plus a numeric readout.
    case slider(min: Double, max: Double, step: Double)
    case toggle
    case picker([PickerOption])
}

struct ToolParameter: Identifiable, Sendable {
    let id: String
    let label: String
    var hint: String? = nil
    var kind: ParameterKind
    var defaultValue: ParameterValue
    var visibleWhen: ParameterVisibility = .always
    /// Value used when the user leaves a text field empty.
    var placeholderFallback: String? = nil

    static func text(_ id: String, _ label: String, default def: String = "",
                     placeholder: String = "", hint: String? = nil,
                     visibleWhen: ParameterVisibility = .always) -> ToolParameter {
        .init(id: id, label: label, hint: hint,
              kind: .text(placeholder: placeholder),
              defaultValue: .text(def), visibleWhen: visibleWhen)
    }

    static func number(_ id: String, _ label: String, default def: Double,
                       min: Double = 0, max: Double = 100_000, step: Double = 1,
                       hint: String? = nil,
                       visibleWhen: ParameterVisibility = .always) -> ToolParameter {
        .init(id: id, label: label, hint: hint,
              kind: .number(min: min, max: max, step: step),
              defaultValue: .number(def), visibleWhen: visibleWhen)
    }

    static func slider(_ id: String, _ label: String, default def: Double,
                       min: Double, max: Double, step: Double = 1,
                       hint: String? = nil,
                       visibleWhen: ParameterVisibility = .always) -> ToolParameter {
        .init(id: id, label: label, hint: hint,
              kind: .slider(min: min, max: max, step: step),
              defaultValue: .number(def), visibleWhen: visibleWhen)
    }

    static func toggle(_ id: String, _ label: String, default def: Bool = false,
                       hint: String? = nil,
                       visibleWhen: ParameterVisibility = .always) -> ToolParameter {
        .init(id: id, label: label, hint: hint, kind: .toggle,
              defaultValue: .bool(def), visibleWhen: visibleWhen)
    }

    static func picker(_ id: String, _ label: String, default def: String,
                       options: [PickerOption], hint: String? = nil,
                       visibleWhen: ParameterVisibility = .always) -> ToolParameter {
        .init(id: id, label: label, hint: hint, kind: .picker(options),
              defaultValue: .choice(def), visibleWhen: visibleWhen)
    }
}

// MARK: - Tool context

/// Everything a tool needs to do its work.
struct ToolContext: @unchecked Sendable {
    let toolID: String
    let inputs: [URL]
    let outputDirectory: URL
    let values: [String: ParameterValue]
    let settings: AppSettings
    let progress: ProgressReporter
    let handle: ProcessHandle
    let logger: JobLogger

    // Typed accessors with sane fallbacks.
    func string(_ key: String, _ fallback: String = "") -> String {
        guard let v = values[key] else { return fallback }
        let s = v.stringValue
        return s.isEmpty ? fallback : s
    }
    func double(_ key: String, _ fallback: Double = 0) -> Double {
        values[key]?.doubleValue ?? fallback
    }
    func int(_ key: String, _ fallback: Int = 0) -> Int {
        Int(values[key]?.doubleValue ?? Double(fallback))
    }
    func bool(_ key: String, _ fallback: Bool = false) -> Bool {
        values[key]?.boolValue ?? fallback
    }
    func choice(_ key: String, _ fallback: String = "") -> String {
        values[key]?.stringValue ?? fallback
    }

    /// The first input, if the tool has one. Tools like the QR generator and
    /// the file renamer run without any input, so this must stay optional.
    var firstInput: URL? { inputs.first }

    /// Destination URL honouring the user's output-location preference.
    func output(_ filename: String) -> URL {
        outputDirectory.appendingPathComponent(filename)
    }

    /// Destination derived from the first input's base name, falling back to a
    /// neutral name when there is no input.
    func output(ext: String, suffix: String = "") -> URL {
        let base = inputs.first?.deletingPathExtension().lastPathComponent ?? L("enum.filter.all.3")
        return output("\(base)\(suffix).\(ext)")
    }

    func output(index: Int, ext: String, suffix: String = "") -> URL {
        guard inputs.indices.contains(index) else {
            return output(ext: ext, suffix: suffix)
        }
        let base = inputs[index].deletingPathExtension().lastPathComponent
        return output("\(base)\(suffix).\(ext)")
    }

    /// A private scratch directory for intermediate files.
    func makeScratch() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("FormatForge/\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func checkCancelled() throws {
        if handle.isCancelled { throw ProcessError.cancelled }
    }
}

/// Bridge that lets tools push progress into the job queue from any thread.
final class ProgressReporter: @unchecked Sendable {
    private let handler: @Sendable (Double, String?) -> Void

    init(_ handler: @escaping @Sendable (Double, String?) -> Void) {
        self.handler = handler
    }


    func report(_ fraction: Double, _ note: String? = nil) {
        handler(min(max(fraction, 0), 1), note)
    }

    func note(_ text: String) { handler(-1, text) }

    static let silent = ProgressReporter { _, _ in }
}

// MARK: - Tool definition

/// What a tool produces. Drives the action button's label and whether the
/// run is expected to write files at all.
enum ToolResultKind: String, Sendable {
    /// Writes one or more new files (the common case).
    case files
    /// Only inspects and reports; writes nothing.
    case report
    /// Modifies files in place rather than producing new ones.
    case inPlace

    /// Verb shown on the primary button.
    var actionTitle: String {
        switch self {
        case .files: return L("ui.start")
        case .report: return L("enum.resultkind.inplace")
        case .inPlace: return L("enum.resultkind.inplace.2")
        }
    }
}

/// A single conversion capability surfaced in the UI.
struct Tool: Identifiable, Sendable {
    let id: String
    let name: String
    let summary: String
    let symbol: String
    let category: ToolCategory
    /// Accepted input file extensions (lowercase, no dot). Empty means any.
    let accepts: [String]
    var allowsMultiple: Bool = true
    /// External dependencies that must be present before the tool can run.
    var requiresFFmpeg: Bool = false
    var requiresSevenZip: Bool = false
    /// What this tool produces; controls the action label and result handling.
    var resultKind: ToolResultKind = .files
    /// Label for the primary action button. Defaults to the result kind's verb,
    /// overridden per tool when a more specific word reads better.
    var actionTitle: String? = nil
    /// Per-mode button labels, keyed by "parameter=value". Lets a tool whose
    /// behaviour depends on a picker (generate vs read, encrypt vs decrypt)
    /// show an accurate verb instead of one generic word.
    var actionVariants: [String: String] = [:]
    var parameters: [ToolParameter] = []
    /// Tools that render a bespoke editor instead of the generic form.
    var hasCustomEditor: Bool = false
    /// Minimum inputs required before the Run button enables.
    var minimumInputs: Int = 1
    /// Whether an output folder is meaningful for this tool.
    var writesFiles: Bool { resultKind != .report }

    /// Inspection tools compute automatically on input change and render their
    /// findings inline, so they need no button and no task queue entry.
    var inspector: (any FileInspector)? = nil
    var isInspection: Bool { inspector != nil }

    let run: @Sendable (ToolContext) async throws -> [URL]

    /// The verb shown on the primary button, resolved against current values.
    func primaryAction(values: [String: ParameterValue]) -> String {
        for (key, label) in actionVariants {
            // Keys look like "action=read"; the first match wins.
            let parts = key.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let parameter = String(parts[0])
            let expected = String(parts[1])
            if values[parameter]?.stringValue == expected { return label }
        }
        return actionTitle ?? resultKind.actionTitle
    }

    /// Whether this tool writes files, accounting for modes that only report.
    func writesFiles(values: [String: ParameterValue]) -> Bool {
        if resultKind == .report { return false }
        // A dry-run preview produces no files by design.
        if values["dryRun"]?.boolValue == true { return false }
        return true
    }

    /// The verb shown on the primary button (mode-independent fallback).
    var primaryAction: String { actionTitle ?? resultKind.actionTitle }

    /// An inspection tool never needs a manual trigger.
    var needsRunButton: Bool { !isInspection }

    func acceptsURL(_ url: URL) -> Bool {
        guard !accepts.isEmpty else { return true }
        return accepts.contains(url.pathExtension.lowercased())
    }
}

// MARK: - Registry helpers

extension Tool {
    /// Human readable list of accepted extensions for the drop zone.
    var acceptDescription: String {
        accepts.isEmpty ? L("ui.any_file") : accepts.map { $0.uppercased() }.joined(separator: " · ")
    }
}
