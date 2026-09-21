import SwiftUI
import AppKit

// MARK: - Inspector

struct InspectorPanel: View {
    @Environment(AppState.self) private var state
    @State private var tab: Tab = .queue
    /// Job whose log is displayed; follows the newest by default.
    @State private var inspectedJobID: UUID?

    enum Tab: String, CaseIterable, Identifiable {
        case queue, log, info
        var id: String { rawValue }
        var label: String {
            switch self {
            case .queue: return L("enum.tab.queue")
            case .log: return L("enum.tab.queue.2")
            case .info: return L("enum.tab.queue.3")
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Metrics.s2) {
                SegmentPicker(
                    options: Tab.allCases.map { PickerOption($0.rawValue, $0.label) },
                    selection: Binding(
                        get: { tab.rawValue },
                        set: { tab = Tab(rawValue: $0) ?? .queue })
                )
                Spacer(minLength: 0)
                IconButton(symbol: "xmark", size: 20, help: L("ui.hide_j")) {
                    state.showingInspector = false
                }
            }
            .padding(.horizontal, Metrics.s3)
            .frame(height: 34)
            .background(Palette.windowBackground)

            Divider().overlay(Palette.separator)

            switch tab {
            case .queue:
                JobListView(onInspect: { job in
                    inspectedJobID = job.id
                    tab = .log
                })
            case .log:
                JobLogView(jobID: inspectedJobID, selection: $inspectedJobID)
            case .info:
                MediaInfoView()
            }
        }
        .background(Palette.windowBackground)
    }
}

// MARK: - Job list

struct JobListView: View {
    @Environment(AppState.self) private var state
    var onInspect: (Job) -> Void = { _ in }

    var body: some View {
        VStack(spacing: 0) {
            if state.queue.jobs.isEmpty {
                EmptyState(
                    symbol: "tray",
                    title: L("ui.no_tasks_yet"),
                    message: L("ui.start_a_conversion_and_it_appears_here_you")
                )
            } else {
                HStack(spacing: Metrics.s2) {
                    Text(L("ui.state_queue_jobs_count_task_s", state.queue.jobs.count))
                        .font(Type.caption)
                        .foregroundStyle(Palette.textTertiary)
                    Spacer(minLength: 0)
                    if state.queue.hasActivity {
                        SecondaryButton(title: L("ui.cancel_all"), symbol: "stop.fill", compact: true) {
                            state.queue.cancelAll()
                        }
                    }
                    if state.queue.jobs.contains(where: { $0.state.isTerminal }) {
                        SecondaryButton(title: L("ui.clear"), symbol: "trash", compact: true) {
                            state.queue.clearFinished()
                        }
                    }
                }
                .padding(.horizontal, Metrics.s3)
                .frame(height: 30)

                Divider().overlay(Palette.separator)

                ScrollView {
                    LazyVStack(spacing: Metrics.s2) {
                        ForEach(state.queue.jobs) { job in
                            JobRow(job: job, onInspect: { onInspect(job) })
                        }
                    }
                    .padding(Metrics.s3)
                }
            }
        }
    }
}

struct JobRow: View {
    @Environment(AppState.self) private var state
    let job: Job
    var onInspect: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.s2) {
            HStack(spacing: Metrics.s2) {
                ToolIcon(symbol: job.symbol, category: job.accent, size: 20)
                VStack(alignment: .leading, spacing: 0) {
                    // Tool names are 2–3× longer in some languages; wrap to
                    // two lines rather than clipping mid-word.
                    Text(job.toolName)
                        .font(Type.callout.weight(.medium))
                        .foregroundStyle(Palette.textPrimary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(job.inputs.first?.lastPathComponent ?? "")
                        .font(Type.caption)
                        .foregroundStyle(Palette.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: Metrics.s1)
                statusBadge
            }

            switch job.state {
            case .queued:
                Text(L("ui.queued"))
                    .font(Type.caption)
                    .foregroundStyle(Palette.textTertiary)

            case .running:
                VStack(alignment: .leading, spacing: 3) {
                    ProgressBar(value: job.progress, tint: Palette.accent)
                    HStack(spacing: Metrics.s2) {
                        Text(job.note.isEmpty ? L("ui.working") : job.note)
                            .font(Type.caption)
                            .foregroundStyle(Palette.textSecondary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                        Text(Format.percent(job.progress))
                            .font(Type.mono(10))
                            .foregroundStyle(Palette.textSecondary)
                    }
                }

            case .finished(let urls):
                HStack(spacing: Metrics.s2) {
                    Text(L("ui.urls_count_file_s_format_bytes_job_outputb", urls.count, Format.bytes(job.outputBytes)))
                        .font(Type.caption)
                        .foregroundStyle(Palette.success)
                    Spacer(minLength: 0)
                    SecondaryButton(title: L("enum.tab.queue.2"), symbol: "text.alignleft", compact: true, action: onInspect)
                    SecondaryButton(title: L("ui.show"), symbol: "folder", compact: true) {
                        FileIO.reveal(urls)
                    }
                }

            case .failed(let message):
                Text(message)
                    .font(Type.caption)
                    .foregroundStyle(Palette.danger)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)

            case .reported:
                HStack(spacing: Metrics.s2) {
                    Text(L("ui.finished_see_the_log"))
                        .font(Type.caption)
                        .foregroundStyle(Palette.success)
                    Spacer(minLength: 0)
                    SecondaryButton(title: L("enum.tab.queue.2"), symbol: "text.alignleft", compact: true, action: onInspect)
                }

            case .cancelled:
                Text(L("ui.cancelled"))
                    .font(Type.caption)
                    .foregroundStyle(Palette.textTertiary)
            }
        }
        .padding(Metrics.s3)
        .background(
            RoundedRectangle(cornerRadius: Metrics.radius, style: .continuous)
                .fill(Palette.card)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Metrics.radius, style: .continuous)
                .strokeBorder(borderColor, lineWidth: 1)
        )
        .contextMenu {
            Button(L("ui.view_log"), action: onInspect)
            if !job.state.isTerminal {
                Button(L("ui.cancel_task"), role: .destructive) { state.queue.cancel(job) }
            }
            if case .finished(let urls) = job.state {
                Button(L("ui.show_in_finder")) { FileIO.reveal(urls) }
                Button(L("ui.copy_path")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(urls.map(\.path).joined(separator: "\n"), forType: .string)
                }
            }
        }
    }

    private var borderColor: Color {
        if case .failed = job.state { return Palette.danger.opacity(0.35) }
        if job.state.isSuccess { return Palette.success.opacity(0.28) }
        return Palette.border
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch job.state {
        case .queued: Badge(text: L("ui.queued_2"), tint: Palette.textTertiary)
        case .running: Badge(text: L("ui.running"), tint: Palette.accent)
        case .finished: Badge(text: L("ui.done"), tint: Palette.success)
        case .reported: Badge(text: L("ui.done"), tint: Palette.success)
        case .failed: Badge(text: L("ui.failed"), tint: Palette.danger)
        case .cancelled: Badge(text: L("ui.cancelled"), tint: Palette.textTertiary)
        }
    }
}

// MARK: - Media info

struct MediaInfoView: View {
    @Environment(AppState.self) private var state
    @State private var info: MediaInfo?
    @State private var loading = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Metrics.s4) {
                if let url = state.inputs.first {
                    HStack(spacing: Metrics.s2) {
                        Image(systemName: FileGlyph.symbol(for: url))
                            .foregroundStyle(Palette.textTertiary)
                        Text(url.lastPathComponent)
                            .font(Type.callout.weight(.medium))
                            .foregroundStyle(Palette.textPrimary)
                            .lineLimit(2)
                            .truncationMode(.middle)
                    }

                    if loading {
                        HStack(spacing: Metrics.s2) {
                            ProgressView().controlSize(.small)
                            Text(L("ui.reading")).font(Type.footnote).foregroundStyle(Palette.textTertiary)
                        }
                    } else if let info {
                        infoContent(info)
                    } else {
                        Text(L("ui.could_not_read_media_information"))
                            .font(Type.footnote)
                            .foregroundStyle(Palette.textTertiary)
                    }

                    if state.inputs.count > 1 {
                        Text(L("ui.showing_the_first_of_state_inputs_count_fi", state.inputs.count))
                            .font(Type.caption)
                            .foregroundStyle(Palette.textTertiary)
                    }
                } else {
                    EmptyState(
                        symbol: "info.circle",
                        title: L("ui.no_file_selected"),
                        message: L("ui.add_a_file_to_inspect_its_resolution_durat")
                    )
                }
            }
            .padding(Metrics.s4)
        }
        .task(id: state.inputs.first?.path) {
            guard let url = state.inputs.first else { info = nil; return }
            loading = true
            info = await MediaProbe.info(for: url)
            loading = false
        }
    }

    @ViewBuilder
    private func infoContent(_ info: MediaInfo) -> some View {
        VStack(alignment: .leading, spacing: Metrics.s4) {
            // A still image has no timeline: show its real properties instead of
            // duration/frame-rate/bitrate, which would be meaningless.
            if info.hasImage {
                imageGroup()
            } else if info.hasVideo {
                group(L("ui.video")) {
                    StatRow(label: L("ui.dimensions"), value: info.resolution)
                    StatRow(label: L("ui.duration"), value: Format.duration(info.duration))
                    if info.frameRate > 0 {
                        StatRow(label: L("ui.frame_rate"), value: String(format: "%.3f fps", info.frameRate))
                    }
                    if let codec = info.videoCodec {
                        StatRow(label: L("ui.codec"), value: codec.uppercased())
                    }
                    if let pix = info.pixelFormat { StatRow(label: L("ui.pixel_format"), value: pix) }
                    if info.frameCount > 0 { StatRow(label: L("ui.frames"), value: "\(info.frameCount)") }
                    if info.rotation != 0 { StatRow(label: L("ui.rotation"), value: "\(info.rotation)°") }
                }
            }

            if info.hasAudio {
                group(L("ui.audio")) {
                    if let codec = info.audioCodec { StatRow(label: L("ui.codec"), value: codec.uppercased()) }
                    if info.sampleRate > 0 { StatRow(label: L("ui.sample_rate"), value: "\(info.sampleRate) Hz") }
                    if info.channelCount > 0 { StatRow(label: L("ui.channels"), value: "\(info.channelCount)") }
                    if info.duration > 0 { StatRow(label: L("ui.duration"), value: Format.duration(info.duration)) }
                }
            }

            group(L("ui.file")) {
                StatRow(label: L("ui.type"), value: info.kind.label)
                // Bitrate and container only mean something for timed media.
                if info.hasTimeline, info.bitRate > 0 {
                    StatRow(label: L("ui.bitrate"), value: String(format: "%.2f Mbps", Double(info.bitRate) / 1_000_000))
                }
                if info.hasTimeline, !info.containerFormat.isEmpty {
                    StatRow(label: L("ui.container"), value: info.containerFormat)
                }
                if let url = state.inputs.first {
                    StatRow(label: L("ui.format"), value: url.pathExtension.uppercased())
                    StatRow(label: L("ui.size"), value: Format.bytes(FileIO.size(of: url)))
                }
            }
        }
    }

    /// Real image metadata: dimensions, DPI, colour model, EXIF and GPS.
    @ViewBuilder
    private func imageGroup() -> some View {
        if let url = state.inputs.first {
            let metadata = ImageSupport.metadata(of: url)
            group(L("ui.image")) {
                if let size = ImageSupport.size(of: url) {
                    StatRow(label: L("ui.dimensions"), value: "\(Int(size.width)) × \(Int(size.height))")
                    StatRow(label: L("ui.pixels"), value: Format.pixels(Int(size.width * size.height)))
                    StatRow(label: L("ui.aspect_ratio"), value: Format.aspect(width: size.width, height: size.height))
                }
                // Ordered so the most useful rows come first.
                ForEach([L("ui.format"), L("ui.dimensions"), L("ui.bit_depth"), L("ui.transparency"), L("ui.colour_model")], id: \.self) { key in
                    if let value = metadata[key] { StatRow(label: key, value: value) }
                }
            }

            let exif = [L("ui.make"), L("ui.model"), L("ui.exposure"), L("ui.aperture"), "ISO", "GPS"]
            let present = exif.filter { metadata[$0] != nil }
            if !present.isEmpty {
                group(L("ui.capture")) {
                    ForEach(present, id: \.self) { key in
                        StatRow(label: key, value: metadata[key] ?? "")
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Metrics.s2) {
            Text(title)
                .font(Type.caption.weight(.semibold))
                .foregroundStyle(Palette.textTertiary)
            VStack(spacing: Metrics.s2) { content() }
        }
        .padding(Metrics.s3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Metrics.radius, style: .continuous)
                .fill(Palette.card)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Metrics.radius, style: .continuous)
                .strokeBorder(Palette.border, lineWidth: 1)
        )
    }
}

// MARK: - Job log

/// Detailed, timestamped activity log for a single job, including the exact
/// command lines that were executed.
struct JobLogView: View {
    @Environment(AppState.self) private var state
    let jobID: UUID?
    @Binding var selection: UUID?

    @State private var filter: Filter = .all
    @State private var autoScroll = true

    enum Filter: String, CaseIterable, Identifiable {
        case all, command, output, errors
        var id: String { rawValue }
        var label: String {
            switch self {
            case .all: return L("enum.filter.all")
            case .command: return L("enum.filter.all.2")
            case .output: return L("enum.filter.all.3")
            case .errors: return L("enum.filter.all.4")
            }
        }
    }

    private var job: Job? {
        if let jobID, let match = state.queue.jobs.first(where: { $0.id == jobID }) { return match }
        return state.queue.jobs.first
    }

    private var entries: [LogEntry] {
        guard let job else { return [] }
        switch filter {
        case .all: return job.entries
        case .command: return job.entries.filter { $0.level == .command }
        case .output: return job.entries.filter { $0.level == .output }
        case .errors: return job.entries.filter { $0.level == .error || $0.level == .warning }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if state.queue.jobs.isEmpty {
                EmptyState(symbol: "text.alignleft", title: L("ui.no_log_yet"),
                           message: L("ui.run_a_task_to_see_each_step_the_exact_comm"))
            } else {
                header
                Divider().overlay(Palette.separator)
                content
                Divider().overlay(Palette.separator)
                footer
            }
        }
    }

    private var header: some View {
        VStack(spacing: Metrics.s2) {
            HStack(spacing: Metrics.s2) {
                if let job {
                    ToolIcon(symbol: job.symbol, category: job.accent, size: 18)
                    Text(job.toolName)
                        .font(Type.callout.weight(.medium))
                        .foregroundStyle(Palette.textPrimary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)

                if state.queue.jobs.count > 1 {
                    Menu {
                        ForEach(state.queue.jobs) { candidate in
                            Button {
                                selection = candidate.id
                            } label: {
                                Text("\(candidate.toolName) · \(candidate.inputs.first?.lastPathComponent ?? "")")
                            }
                        }
                    } label: {
                        Image(systemName: "list.bullet")
                            .font(.system(size: 10))
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .frame(width: 22)
                }

                IconButton(symbol: "doc.on.doc", size: 20, help: L("ui.copy_all")) {
                    let text = entries.map { "\($0.timeLabel)  \($0.text)" }.joined(separator: "\n")
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    state.showToast(L("ui.log_copied"), kind: .success)
                }
            }
            .padding(.horizontal, Metrics.s3)
            .padding(.top, Metrics.s3)

            SegmentPicker(
                options: Filter.allCases.map { PickerOption($0.rawValue, $0.label) },
                selection: Binding(get: { filter.rawValue },
                                   set: { filter = Filter(rawValue: $0) ?? .all })
            )
            .padding(.horizontal, Metrics.s3)
            .padding(.bottom, Metrics.s3)
        }
    }

    @ViewBuilder
    private var content: some View {
        if entries.isEmpty {
            EmptyState(symbol: "text.alignleft",
                       title: filter == .all ? L("ui.no_log_yet") : L("ui.nothing_in_this_category"),
                       message: filter == .all ? "" : L("ui.switch_to_all_for_the_full_record"))
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(entries) { entry in
                            LogRow(entry: entry).id(entry.id)
                        }
                    }
                    .padding(.vertical, Metrics.s2)
                    .padding(.horizontal, Metrics.s2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: entries.count) { _, _ in
                    guard autoScroll, let last = entries.last else { return }
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: Metrics.s2) {
            if let job {
                Text(L("ui.job_entries_count_entries", job.entries.count))
                    .font(Type.mono(9))
                    .foregroundStyle(Palette.textTertiary)
                if job.state.isTerminal {
                    Text(String(format: "%.2fs", job.elapsed))
                        .font(Type.mono(9))
                        .foregroundStyle(Palette.textTertiary)
                }
            }
            Spacer(minLength: 0)
            Toggle(isOn: $autoScroll) {
                Text(L("ui.auto_scroll")).font(Type.caption)
            }
            .toggleStyle(.checkbox)
            .controlSize(.small)
        }
        .padding(.horizontal, Metrics.s3)
        .frame(height: 26)
    }
}

/// A single log line, colour-coded by level.
private struct LogRow: View {
    let entry: LogEntry

    private var color: Color {
        switch entry.level {
        case .info: return Palette.textSecondary
        case .command: return Palette.accent
        case .output: return Palette.textTertiary
        case .success: return Palette.success
        case .warning: return Palette.warning
        case .error: return Palette.danger
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: Metrics.s2) {
            Text(entry.timeLabel)
                .font(Type.mono(9))
                .foregroundStyle(Palette.textQuaternary)
                .frame(width: 58, alignment: .leading)

            Image(systemName: entry.level.symbol)
                .font(.system(size: entry.level == .info ? 5 : 8, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 9)
                .padding(.top, entry.level == .info ? 4 : 2)

            Text(entry.text)
                .font(entry.level == .command || entry.level == .output
                      ? Type.mono(10) : Type.caption)
                .foregroundStyle(color)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 1)
    }
}
