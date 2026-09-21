import Foundation
import AppKit
import ImageIO
import UniformTypeIdentifiers
import AVFoundation
import CoreGraphics

// MARK: - Checksum inspector

/// Computes every checksum in one pass, plus optional verification.
struct HashInspector: FileInspector {
    func inspect(
        inputs: [URL],
        values: [String: ParameterValue],
        progress: @escaping @Sendable (Double) -> Void
    ) async -> InspectionReport {
        let expected = values["expected"]?.stringValue ?? ""
        let verifyAlgorithm = HashAlgorithm(rawValue: values["verifyAlgorithm"]?.stringValue ?? "")
            ?? .sha256

        var sections: [InspectionReport.Section] = []
        var totalSeconds: Double = 0
        var totalBytes: Int64 = 0

        for (index, url) in inputs.enumerated() {
            let result = HashEngine.hash(url, algorithms: HashAlgorithm.allCases) { fraction in
                progress((Double(index) + fraction) / Double(inputs.count))
            }
            totalSeconds += result.seconds
            totalBytes += result.bytes

            guard result.ok else {
                sections.append(.init(id: url.path, title: url.lastPathComponent,
                                      symbol: "xmark.circle", rows: [],
                                      note: result.error))
                continue
            }

            var rows: [InspectionReport.Row] = [
                .init(id: "size", label: L("ui.file_size"), value: Format.bytes(result.bytes), mono: true),
                .init(id: "time", label: L("ui.read_time"),
                      value: String(format: L("ui.2f_s"), result.seconds), mono: true),
            ]

            for algorithm in HashAlgorithm.allCases {
                guard let value = result.values[algorithm] else { continue }
                var status: InspectionReport.Row.Status? = nil
                // Verify against the expected value when one was supplied.
                if !expected.isEmpty, algorithm == verifyAlgorithm {
                    status = value.lowercased() == expected.lowercased() ? .ok : .failed
                }
                rows.append(.init(id: algorithm.rawValue, label: algorithm.label,
                                  value: value, mono: true, copyable: true, status: status))
            }

            // When an expected value is supplied, state the verdict explicitly.
            if !expected.isEmpty {
                let matched = result.values[verifyAlgorithm]?.lowercased() == expected.lowercased()
                rows.append(.init(id: "verdict", label: L("ui.verification"),
                                  value: matched ? L("ui.match") : L("ui.mismatch"),
                                  mono: false,
                                  status: matched ? .ok : .failed))
            }

            sections.append(.init(
                id: url.path,
                title: inputs.count > 1 ? url.lastPathComponent : L("ui.verification"),
                symbol: "number",
                rows: rows,
                note: inputs.count > 1 ? nil : url.lastPathComponent))
        }

        let summary = String(
            format: L("ui.d_file_s_read_in_2f_s"),
            inputs.count, Format.bytes(totalBytes), totalSeconds)

        return InspectionReport(sections: sections, summary: summary, seconds: totalSeconds)
    }
}
