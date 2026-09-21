import Foundation

// MARK: - Report model

/// Structured results from an inspection tool.
///
/// Inspection tools do not "run" — they compute automatically whenever the
/// input changes and render their findings inline in the workspace, so there is
/// no button to press and no need to hunt for the right panel.
struct InspectionReport: Sendable {
    struct Row: Sendable, Identifiable {
        let id: String
        let label: String
        let value: String
        /// Rendered in a monospaced font (hashes, paths, numbers).
        var mono: Bool = false
        /// Offers a copy button; defaults on for mono values.
        var copyable: Bool = false
        /// Optional verification outcome.
        var status: Status? = nil

        enum Status: Sendable { case ok, failed, neutral }
    }

    struct Section: Sendable, Identifiable {
        let id: String
        let title: String
        var symbol: String = "info.circle"
        var rows: [Row] = []
        /// Free-form note shown under the rows.
        var note: String? = nil
    }

    var sections: [Section] = []
    /// One-line headline, e.g. "1.5 MB · 读取耗时 0.03 秒".
    var summary: String? = nil
    var error: String? = nil
    var seconds: Double = 0

    var isEmpty: Bool { sections.allSatisfy { $0.rows.isEmpty } }

    static func failure(_ message: String) -> InspectionReport {
        InspectionReport(sections: [], summary: nil, error: message)
    }
}

// MARK: - Inspector protocol

/// A tool that inspects files rather than converting them.
protocol FileInspector: Sendable {
    /// Compute the report for the given inputs.
    func inspect(inputs: [URL], values: [String: ParameterValue],
                 progress: @escaping @Sendable (Double) -> Void) async -> InspectionReport
}
