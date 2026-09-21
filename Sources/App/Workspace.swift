import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Workspace

struct ToolWorkspace: View {
    @Environment(AppState.self) private var state

    var body: some View {
        @Bindable var state = state
        VStack(spacing: 0) {
            ToolHeader()
            Divider().overlay(Palette.separator)

            ScrollView {
                VStack(alignment: .leading, spacing: Metrics.s5) {
                    InputSection()

                    // Inspection tools report inline and never need presets,
                    // estimates or an output folder.
                    if state.isInspectionTool {
                        if !state.selectedTool.parameters.isEmpty {
                            parametersSection
                        }
                        InspectionReportView(
                            report: state.report,
                            isComputing: state.isInspecting,
                            inputCount: state.inputs.count
                        )
                    } else {
                        if !state.currentPresets.isEmpty {
                            PresetSection()
                        }

                        if state.selectedTool.hasCustomEditor {
                            CustomEditorHost(tool: state.selectedTool)
                        } else if !state.selectedTool.parameters.isEmpty {
                            parametersSection
                        }

                        if !state.selectedTool.parameters.isEmpty || state.selectedTool.hasCustomEditor {
                            EstimateSection()
                            OutputSection()
                        }
                    }
                }
                .padding(Metrics.s5)
                .frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .center)
            }

            RunBar()
        }
        .background(Palette.contentBackground)
    }

    /// Parameters, with a codec explainer when the tool chooses an encoder.
    private var parametersSection: some View {
        @Bindable var state = state
        let codec = VideoCodec(rawValue: state.parameterValues["codec"]?.stringValue ?? "")
        let audio = AudioCodec(rawValue: state.parameterValues["audioCodec"]?.stringValue ?? "")
        let showsCodec = state.selectedTool.parameters.contains { $0.id == "codec" }

        return Section(
            title: L("ui.parameters"),
            subtitle: state.presetIsModified ? L("ui.manually_modified") : nil,
            symbol: "slider.horizontal.3",
            accessory: state.presetIsModified
                ? AnyView(
                    Button(L("ui.reset_to_preset")) {
                        if let id = state.selectedPreset?.id { state.applyPreset(id: id) }
                    }
                    .buttonStyle(.link)
                    .font(Type.caption)
                )
                : nil
        ) {
            VStack(alignment: .leading, spacing: Metrics.s4) {
                ParameterForm(
                    parameters: state.selectedTool.parameters,
                    values: $state.parameterValues,
                    accent: Palette.accent
                )
                .onChange(of: state.parameterValues) { _, _ in
                    state.parametersChanged()
                }

                if showsCodec, let codec {
                    Divider().overlay(Palette.separator)
                    CodecExplainer(codec: codec, audio: audio)
                }
            }
        }
    }
}

// MARK: - Header

struct ToolHeader: View {
    @Environment(AppState.self) private var state

    var body: some View {
        let tool = state.selectedTool
        HStack(spacing: Metrics.s3) {
            ToolIcon(symbol: tool.symbol, category: tool.category, size: 26)

            VStack(alignment: .leading, spacing: 1) {
                Text(tool.name)
                    .font(Type.title)
                    .foregroundStyle(Palette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                // The summary is a full sentence and is 2–3× longer in some
                // languages, so it gets two lines before eliding.
                Text(tool.summary)
                    .font(Type.footnote)
                    .foregroundStyle(Palette.textSecondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .layoutPriority(1)

            Spacer(minLength: Metrics.s3)

            if tool.isInspection {
                Badge(text: L("ui.automatic"), tint: Palette.accent)
            }
            // The accepted formats are listed inside the drop zone, which is
            // where the user actually needs them. Repeating the list here only
            // competed with the summary for width — in Portuguese it squeezed
            // the summary to three words and itself to "MP…TS".

            IconButton(symbol: "sidebar.right", size: 24, help: L("ui.show_or_hide_the_task_panel_j")) {
                state.showingInspector.toggle()
            }
        }
        .padding(.horizontal, Metrics.s5)
        .padding(.vertical, Metrics.s3)
        .background(Palette.windowBackground)
        .background(WindowDragArea())
    }
}

// MARK: - Inputs

struct InputSection: View {
    @Environment(AppState.self) private var state

    var body: some View {
        let tool = state.selectedTool
        Section(
            title: L("ui.input_files"),
            subtitle: state.inputs.isEmpty ? nil : L("ui.state_inputs_count_item_s", state.inputs.count),
            symbol: "tray.and.arrow.down"
        ) {
            VStack(spacing: Metrics.s3) {
                if state.inputs.isEmpty {
                    DropZone(
                        acceptDescription: tool.acceptDescription,
                        allowsMultiple: tool.allowsMultiple,
                        accent: Palette.accent,
                        onFiles: { state.addInputs($0) },
                        onBrowse: openPanel
                    )
                } else {
                    FileListView(
                        files: state.inputs,
                        accent: Palette.accent,
                        onRemove: { state.removeInput(at: $0) },
                        onClear: { state.clearInputs() },
                        onReorder: tool.allowsMultiple ? { state.moveInput(from: $0, to: $1) } : nil,
                        onReveal: { FileIO.reveal(state.inputs) }
                    )

                    HStack(spacing: Metrics.s2) {
                        SecondaryButton(title: L("ui.add_more"), symbol: "plus", action: openPanel)
                        if tool.allowsMultiple && state.inputs.count > 1 {
                            SecondaryButton(title: L("ui.reverse_order"), symbol: "arrow.up.arrow.down") {
                                state.reorderInputs(state.inputs.reversed())
                            }
                            SecondaryButton(title: L("ui.sort_by_name"), symbol: "textformat.abc") {
                                state.reorderInputs(state.inputs.sorted {
                                    $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent)
                                        == .orderedAscending
                                })
                            }
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
        }
    }

    private func openPanel() {
        let tool = state.selectedTool
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = tool.allowsMultiple
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.message = L("ui.choose_input_files")
        panel.prompt = L("ui.add")
        if !tool.accepts.isEmpty {
            panel.allowedContentTypes = tool.accepts.compactMap { UTType(filenameExtension: $0) }
        }
        if panel.runModal() == .OK {
            state.addInputs(panel.urls)
        }
    }
}

// MARK: - Presets

struct PresetSection: View {
    @Environment(AppState.self) private var state

    var body: some View {
        Section(title: L("ui.preset"), symbol: "wand.and.stars") {
            VStack(alignment: .leading, spacing: Metrics.s3) {
                // A menu keeps the panel compact even with many templates.
                PopUpPicker(
                    options: state.currentPresets.map {
                        PickerOption($0.id, $0.label, detail: $0.detail)
                    },
                    selection: Binding(
                        get: { state.selectedPresetID },
                        set: { state.applyPreset(id: $0) }
                    )
                )

                if let preset = state.selectedPreset {
                    HStack(alignment: .top, spacing: Metrics.s2) {
                        Image(systemName: preset.symbol)
                            .font(.system(size: 11))
                            .foregroundStyle(Palette.accent)
                            .padding(.top, 1)
                        Text(preset.detail)
                            .font(Type.footnote)
                            .foregroundStyle(Palette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                }
            }
        }
    }
}

// MARK: - Estimate

struct EstimateSection: View {
    @Environment(AppState.self) private var state

    var body: some View {
        Section(title: L("ui.estimate"), symbol: "chart.bar") {
            if let estimate = state.estimate, estimate.outputBytes != nil {
                VStack(alignment: .leading, spacing: Metrics.s3) {
                    HStack(alignment: .top, spacing: Metrics.s6) {
                        metric(
                            title: L("ui.expected_size"),
                            value: estimate.sizeLabel,
                            note: estimate.savingLabel,
                            noteTint: estimate.sizeChange?.isReduction == true
                                ? Palette.success : Palette.textTertiary
                        )
                        metric(
                            title: L("ui.expected_time"),
                            value: estimate.timeLabel,
                            note: L("ui.based_on_this_mac"),
                            noteTint: Palette.textTertiary
                        )
                        Spacer(minLength: 0)
                    }

                    Text(estimate.basis + (estimate.approximate ? L("ui.estimate_2") : ""))
                        .font(Type.caption)
                        .foregroundStyle(Palette.textTertiary)
                }
            } else {
                Text(state.inputs.isEmpty
                     ? L("ui.add_files_to_see_the_size_and_time_estimat")
                     : L("ui.computing"))
                    .font(Type.footnote)
                    .foregroundStyle(Palette.textTertiary)
            }
        }
    }

    private func metric(title: String, value: String, note: String?, noteTint: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(Type.caption)
                .foregroundStyle(Palette.textTertiary)
            Text(value)
                .font(Type.rounded(18, weight: .semibold))
                .foregroundStyle(Palette.textPrimary)
            if let note {
                Text(note)
                    .font(Type.caption2)
                    .foregroundStyle(noteTint)
            }
        }
        .frame(minWidth: 110, alignment: .leading)
    }
}

// MARK: - Output

struct OutputSection: View {
    @Environment(AppState.self) private var state

    var body: some View {
        @Bindable var state = state
        Section(title: L("enum.filter.all.3"), symbol: "folder") {
            VStack(alignment: .leading, spacing: Metrics.s3) {
                FieldRow(label: L("ui.location")) {
                    SegmentPicker(
                        options: AppSettings.OutputMode.allCases.map { PickerOption($0.rawValue, $0.label) },
                        selection: Binding(
                            get: { state.settings.outputMode.rawValue },
                            set: {
                                state.settings.outputMode = AppSettings.OutputMode(rawValue: $0) ?? .alongsideInput
                                state.session.outputDirectory = nil
                            }
                        )
                    )
                }

                // Always show the resolved destination so the setting is never
                // silently ignored.
                HStack(spacing: Metrics.s2) {
                    Image(systemName: "arrow.turn.down.right")
                        .font(.system(size: 10))
                        .foregroundStyle(Palette.textTertiary)
                    Text(state.resolvedOutputDirectory.path)
                        .font(Type.mono(11))
                        .foregroundStyle(Palette.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                }

                if state.settings.outputMode == .customFolder {
                    HStack(spacing: Metrics.s2) {
                        SecondaryButton(
                            title: state.settings.needsFolderSelection ? L("ui.choose_output_folder_2") : L("ui.change_folder"),
                            symbol: "folder"
                        ) {
                            if let url = AppState.promptForFolder(
                                message: L("ui.choose_default_output_folder"), prompt: L("ui.choose_2")) {
                                state.settings.customOutputPath = url.path
                            }
                        }
                        if state.settings.needsFolderSelection {
                            Text(L("ui.no_folder_chosen_files_go_next_to_the_orig"))
                                .font(Type.caption)
                                .foregroundStyle(Palette.warning)
                        }
                        Spacer(minLength: 0)
                    }
                }

                HStack(spacing: Metrics.s2) {
                    if state.outputDirectory != nil {
                        Badge(text: L("ui.chosen_for_this_run"), tint: Palette.accent)
                        SecondaryButton(title: L("ui.cancelled"), symbol: "xmark", compact: true) {
                            state.outputDirectory = nil
                        }
                    } else {
                        SecondaryButton(title: L("ui.choose_folder_for_this_run"), symbol: "folder.badge.plus") {
                            if let url = AppState.promptForFolder(
                                message: L("ui.choose_output_folder_for_this_run"), prompt: L("ui.use")) {
                                state.outputDirectory = url
                            }
                        }
                    }
                    Spacer(minLength: 0)
                }

                Divider().overlay(Palette.separator)

                FieldRow(label: L("ui.if_a_file_exists"), inline: true) {
                    PopUpPicker(
                        options: AppSettings.ConflictPolicy.allCases.map { PickerOption($0.rawValue, $0.label) },
                        selection: Binding(
                            get: { state.settings.conflictPolicy.rawValue },
                            set: { state.settings.conflictPolicy = AppSettings.ConflictPolicy(rawValue: $0) ?? .rename }
                        )
                    )
                    .frame(width: 110)
                }

                FieldRow(label: L("ui.show_in_finder_when_done"), inline: true) {
                    SwitchToggle(isOn: Binding(
                        get: { state.settings.revealInFinderWhenDone },
                        set: { state.settings.revealInFinderWhenDone = $0 }
                    ))
                }
            }
        }
    }
}

// MARK: - Run bar

struct RunBar: View {
    @Environment(AppState.self) private var state

    var body: some View {
        let tool = state.selectedTool
        HStack(spacing: Metrics.s3) {
            status

            Spacer(minLength: Metrics.s3)

            if state.queue.hasActivity {
                HStack(spacing: Metrics.s2) {
                    ProgressRing(value: overallProgress, tint: Palette.accent, size: 14)
                    Text(L("ui.state_queue_activecount_task_s_running", state.queue.activeCount))
                        .font(Type.footnote)
                        .foregroundStyle(Palette.textSecondary)
                    Button(L("ui.view")) { state.showingInspector = true }
                        .buttonStyle(.link)
                        .font(Type.footnote)
                }
            }

            // Inspection tools have nothing to trigger: results are already
            // on screen. Only conversion tools get a button.
            if state.selectedTool.needsRunButton {
                PrimaryButton(
                    title: state.primaryActionTitle,
                    symbol: "play.fill",
                    enabled: state.canRun,
                    action: { state.run() }
                )
            }
        }
        .padding(.horizontal, Metrics.s5)
        .padding(.vertical, Metrics.s3)
        .background(Palette.windowBackground)
        .overlay(alignment: .top) { Divider().overlay(Palette.separator) }
    }

    @ViewBuilder
    private var status: some View {
        if let missing = state.missingDependency {
            Label(missing, systemImage: "exclamationmark.triangle.fill")
                .font(Type.footnote)
                .foregroundStyle(Palette.warning)
                .lineLimit(1)
        } else if state.isInspectionTool {
            HStack(spacing: Metrics.s1) {
                Text(L("ui.state_inputs_count_file_s", state.inputs.count))
                Text("·")
                Text(state.isInspecting ? L("ui.computing") : L("ui.results_shown_above"))
            }
            .font(Type.footnote)
            .foregroundStyle(Palette.textTertiary)
        } else if state.inputs.isEmpty {
            Text(L("ui.add_at_least_state_selectedtool_minimuminp", state.selectedTool.minimumInputs))
                .font(Type.footnote)
                .foregroundStyle(Palette.textTertiary)
        } else {
            HStack(spacing: Metrics.s1) {
                Text(L("ui.state_inputs_count_file_s", state.inputs.count))
                if state.writesFiles {
                    Text("·")
                    Text(state.outputSummary)
                    if let estimate = state.estimate {
                        Text("·")
                        Text(L("ui.about_estimate_sizelabel", estimate.sizeLabel))
                            .foregroundStyle(Palette.textSecondary)
                    }
                } else {
                    Text("·")
                    Text(L("ui.results_appear_in_the_log"))
                }
            }
            .font(Type.footnote)
            .foregroundStyle(Palette.textTertiary)
            .lineLimit(1)
        }
    }

    private var overallProgress: Double {
        let active = state.queue.jobs.filter { !$0.state.isTerminal }
        guard !active.isEmpty else { return 0 }
        return active.map(\.progress).reduce(0, +) / Double(active.count)
    }
}

// MARK: - Custom editors

struct CustomEditorHost: View {
    let tool: Tool

    var body: some View {
        switch tool.id {
        case "image.gif": GifBuilderEditor()
        case "video.slideshow": SlideshowEditor()
        default: EmptyView()
        }
    }
}
