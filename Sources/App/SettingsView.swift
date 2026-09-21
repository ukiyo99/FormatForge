import SwiftUI
import AppKit

struct SettingsView: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var state = state
        VStack(spacing: 0) {
            HStack {
                Text(L("ui.settings_2"))
                    .font(Type.title)
                Spacer()
                IconButton(symbol: "xmark", size: 22) { dismiss() }
            }
            .padding(.horizontal, Metrics.s5)
            .frame(height: 42)

            Divider().overlay(Palette.separator)

            ScrollView {
                VStack(alignment: .leading, spacing: Metrics.s4) {
                    languageSection
                    outputSection
                    performanceSection
                    dependencySection
                    aboutSection
                }
                .padding(Metrics.s5)
            }
        }
        .frame(width: Metrics.settingsPaneWidth, height: Metrics.settingsPaneHeight)
        .background(Palette.windowBackground)
    }

    /// Language selection. Shown first because it changes everything below it.
    private var languageSection: some View {
        @Bindable var state = state
        return Section(title: L("settings.language"), symbol: "globe") {
            VStack(alignment: .leading, spacing: Metrics.s2) {
                PopUpPicker(
                    options: Language.allCases.map {
                        PickerOption($0.rawValue, $0.nativeName, detail: $0.englishName)
                    },
                    selection: Binding(
                        get: { state.localization.language.rawValue },
                        set: { code in
                            guard let value = Language(rawValue: code) else { return }
                            state.setLanguage(value)
                        }
                    )
                )
                Text(L("settings.languageHint"))
                    .font(Type.caption)
                    .foregroundStyle(Palette.textTertiary)
            }
        }
    }

    private var outputSection: some View {
        @Bindable var state = state
        return Section(title: L("enum.filter.all.3"), symbol: "folder") {
            VStack(alignment: .leading, spacing: Metrics.s3) {
                FieldRow(label: L("ui.default_location")) {
                    SegmentPicker(
                        options: AppSettings.OutputMode.allCases.map { PickerOption($0.rawValue, $0.label) },
                        selection: Binding(
                            get: { state.settings.outputMode.rawValue },
                            set: { state.settings.outputMode = AppSettings.OutputMode(rawValue: $0) ?? .alongsideInput }
                        )
                    )
                }
                FieldRow(label: L("ui.if_a_file_exists")) {
                    PopUpPicker(
                        options: AppSettings.ConflictPolicy.allCases.map { PickerOption($0.rawValue, $0.label) },
                        selection: Binding(
                            get: { state.settings.conflictPolicy.rawValue },
                            set: { state.settings.conflictPolicy = AppSettings.ConflictPolicy(rawValue: $0) ?? .rename }
                        )
                    )
                }
                FieldRow(label: L("ui.show_in_finder_when_done"), inline: true) {
                    SwitchToggle(isOn: Binding(
                        get: { state.settings.revealInFinderWhenDone },
                        set: { state.settings.revealInFinderWhenDone = $0 }
                    ))
                }
                FieldRow(label: L("ui.keep_metadata_chapters_subtitles_rotation"), inline: true) {
                    SwitchToggle(isOn: Binding(
                        get: { state.settings.keepMetadata },
                        set: { state.settings.keepMetadata = $0 }
                    ))
                }
            }
        }
    }

    private var performanceSection: some View {
        @Bindable var state = state
        return Section(title: L("ui.performance"), symbol: "bolt") {
            VStack(alignment: .leading, spacing: Metrics.s3) {
                FieldRow(label: L("ui.parallel_tasks"),
                         hint: L("ui.how_many_tasks_run_at_once_1_2_is_best_for")) {
                    SliderInput(
                        value: Binding(
                            get: { Double(state.settings.maxConcurrency) },
                            set: {
                                state.settings.maxConcurrency = Int($0)
                                state.queue.maxConcurrency = Int($0)
                            }
                        ),
                        range: 1...8, step: 1,
                        display: { "\(Int($0))" }
                    )
                }
                FieldRow(label: L("ui.enable_hardware_encoding_videotoolbox_by_d"),
                         hint: L("ui.faster_encoding_but_noticeably_larger_file"),
                         inline: true) {
                    SwitchToggle(isOn: Binding(
                        get: { state.settings.useHardwareAcceleration },
                        set: { state.settings.useHardwareAcceleration = $0 }
                    ))
                }
                StatRow(label: L("ui.cpu_cores"), value: "\(ProcessInfo.processInfo.activeProcessorCount)")
            }
        }
    }

    private var dependencySection: some View {
        @Bindable var state = state
        return Section(title: L("ui.dependencies"), symbol: "shippingbox") {
            VStack(alignment: .leading, spacing: Metrics.s3) {
                dependency("ffmpeg / ffprobe", ok: FFmpeg.available,
                           detail: ProcessRunner.locate("ffmpeg") ?? L("ui.not_found_run_brew_install_ffmpeg"))
                dependency(L("ui.7_zip_encrypted_volumes"), ok: ProcessRunner.exists("7z"),
                           detail: ProcessRunner.locate("7z") ?? L("ui.not_found_run_brew_install_p7zip"))
                dependency(L("ui.cwebp_webp_output"), ok: WebPEncoder.isAvailable,
                           detail: ProcessRunner.locate("cwebp") ?? L("ui.not_found_run_brew_install_webp"))
                dependency(L("ui.textutil_document_fallback"), ok: ProcessRunner.exists("textutil"),
                           detail: ProcessRunner.locate("textutil") ?? L("ui.not_found"))

                HStack(spacing: Metrics.s2) {
                    Text(L("ui.custom_ffmpeg_path"))
                        .font(Type.callout)
                        .foregroundStyle(Palette.textPrimary)
                    Spacer(minLength: Metrics.s2)
                    SecondaryButton(title: L("ui.choose"), symbol: "folder", compact: true) {
                        let panel = NSOpenPanel()
                        panel.canChooseFiles = true
                        panel.canChooseDirectories = false
                        if panel.runModal() == .OK, let url = panel.url {
                            state.settings.customFFmpegPath = url.path
                            ProcessRunner.invalidateCache()
                        }
                    }
                }
            }
        }
    }

    private var aboutSection: some View {
        Section(title: L("ui.about"), symbol: "info.circle") {
            VStack(alignment: .leading, spacing: Metrics.s1) {
                Text("FormatForge 1.0")
                    .font(Type.callout.weight(.semibold))
                Text(L("ui.native_swiftui_app_video_work_uses_ffmpeg"))
                    .font(Type.caption)
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func dependency(_ name: String, ok: Bool, detail: String) -> some View {
        HStack(alignment: .top, spacing: Metrics.s2) {
            Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                .font(.system(size: 12))
                .foregroundStyle(ok ? Palette.success : Palette.danger)
            VStack(alignment: .leading, spacing: 0) {
                Text(name)
                    .font(Type.callout)
                    .foregroundStyle(Palette.textPrimary)
                Text(detail)
                    .font(Type.mono(10))
                    .foregroundStyle(Palette.textTertiary)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
    }
}
