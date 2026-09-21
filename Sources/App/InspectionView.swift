import SwiftUI
import AppKit

// MARK: - Inline report

/// Renders an inspection report inline in the workspace.
///
/// Inspection tools have no Run button and no task entry: results appear here
/// as soon as files are added.
struct InspectionReportView: View {
    let report: InspectionReport?
    let isComputing: Bool
    let inputCount: Int

    var body: some View {
        Section(
            title: L("ui.result"),
            subtitle: report?.summary,
            symbol: "doc.text.magnifyingglass",
            accessory: isComputing
                ? AnyView(HStack(spacing: Metrics.s2) {
                    ProgressView().controlSize(.small)
                    Text(L("ui.computing")).font(Type.caption).foregroundStyle(Palette.textTertiary)
                  })
                : nil
        ) {
            if let report {
                if let error = report.error {
                    message(error, symbol: "exclamationmark.triangle.fill", tint: Palette.warning)
                } else if report.isEmpty {
                    message(L("ui.nothing_to_show"), symbol: "questionmark.circle",
                            tint: Palette.textTertiary)
                } else {
                    VStack(alignment: .leading, spacing: Metrics.s4) {
                        ForEach(report.sections) { section in
                            sectionView(section)
                        }
                    }
                }
            } else if isComputing {
                message(L("ui.computing"), symbol: "hourglass", tint: Palette.textTertiary)
            } else {
                message(inputCount == 0 ? L("ui.drop_files_in_to_see_results") : L("ui.preparing"),
                        symbol: "arrow.down.doc", tint: Palette.textTertiary)
            }
        }
    }

    @ViewBuilder
    private func sectionView(_ section: InspectionReport.Section) -> some View {
        if !section.rows.isEmpty || section.note != nil {
            VStack(alignment: .leading, spacing: Metrics.s2) {
                HStack(spacing: Metrics.s2) {
                    Image(systemName: section.symbol)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Palette.textTertiary)
                        .frame(width: 14)
                    Text(section.title)
                        .font(Type.callout.weight(.semibold))
                        .foregroundStyle(Palette.textPrimary)
                    Spacer(minLength: 0)
                }

                VStack(spacing: 0) {
                    ForEach(Array(section.rows.enumerated()), id: \.element.id) { index, row in
                        ReportRowView(row: row)
                        if index < section.rows.count - 1 {
                            Divider().overlay(Palette.separator)
                        }
                    }
                }
                .background(
                    RoundedRectangle(cornerRadius: Metrics.radius, style: .continuous)
                        .fill(Palette.field.opacity(0.5))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Metrics.radius, style: .continuous)
                        .strokeBorder(Palette.border, lineWidth: 1)
                )

                if let note = section.note {
                    Text(note)
                        .font(Type.caption)
                        .foregroundStyle(Palette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func message(_ text: String, symbol: String, tint: Color) -> some View {
        HStack(spacing: Metrics.s2) {
            Image(systemName: symbol)
                .font(.system(size: 12))
                .foregroundStyle(tint)
            Text(text)
                .font(Type.footnote)
                .foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.vertical, Metrics.s2)
    }
}

/// One row of a report: label, value, copy affordance and status.
private struct ReportRowView: View {
    let row: InspectionReport.Row

    @State private var hovering = false
    @State private var copied = false

    private var valueColor: Color {
        switch row.status {
        case .ok: return Palette.success
        case .failed: return Palette.danger
        case .neutral, .none: return Palette.textPrimary
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: Metrics.s3) {
            Text(row.label)
                .font(Type.callout)
                .foregroundStyle(Palette.textSecondary)
                .frame(width: 96, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)

            Text(row.value)
                .font(row.mono ? Type.mono(11.5) : Type.callout)
                .foregroundStyle(valueColor)
                .textSelection(.enabled)
                .lineLimit(4)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)

            if row.status == .ok {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.success)
            } else if row.status == .failed {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.danger)
            }

            // Copy button for values worth pasting elsewhere.
            if row.copyable {
                IconButton(symbol: copied ? "checkmark" : "doc.on.doc",
                           tint: copied ? Palette.success : Palette.textTertiary,
                           size: 18,
                           help: L("ui.copy")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(row.value, forType: .string)
                    copied = true
                    Task {
                        try? await Task.sleep(for: .seconds(1.2))
                        copied = false
                    }
                }
                .opacity(hovering || copied ? 1 : 0.35)
            }
        }
        .padding(.horizontal, Metrics.s3)
        .padding(.vertical, 5)
        .background(hovering ? Palette.hover : Color.clear)
        .onHover { hovering = $0 }
    }
}

// MARK: - Palette swatches

/// Colour chips for the dominant-colour rows.
struct PaletteSwatchRow: View {
    let hexes: [String]

    var body: some View {
        HStack(spacing: Metrics.s2) {
            ForEach(hexes, id: \.self) { hex in
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color(nsColor: ImageSupport.nsColor(from: hex)))
                    .frame(width: 22, height: 22)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .strokeBorder(Palette.border, lineWidth: 1)
                    )
                    .help(hex)
            }
            Spacer(minLength: 0)
        }
    }
}
