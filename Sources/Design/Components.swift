import SwiftUI
import UniformTypeIdentifiers

// MARK: - Tool icon

/// Small tinted glyph identifying a tool. Uses a soft, low-contrast fill so a
/// long list stays visually quiet.
struct ToolIcon: View {
    let symbol: String
    let category: ToolCategory
    var size: CGFloat = 22

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
            .fill(category.accent.opacity(0.14))
            .frame(width: size, height: size)
            .overlay(
                Image(systemName: symbol)
                    .font(.system(size: size * 0.48, weight: .medium))
                    .foregroundStyle(category.accent)
            )
    }
}

// MARK: - Section

/// A titled group of controls, following the macOS settings-pane idiom.
struct Section<Content: View>: View {
    let title: String
    var subtitle: String? = nil
    var symbol: String? = nil
    var accessory: AnyView? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.s3) {
            HStack(spacing: Metrics.s2) {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Palette.textTertiary)
                        .frame(width: 14)
                }
                Text(title)
                    .font(Type.headline)
                    .foregroundStyle(Palette.textPrimary)
                if let subtitle {
                    Text(subtitle)
                        .font(Type.caption)
                        .foregroundStyle(Palette.textTertiary)
                }
                Spacer(minLength: Metrics.s2)
                if let accessory { accessory }
            }
            content
        }
        .card()
    }
}

// MARK: - Buttons

/// The primary action. Uses the system accent colour and the standard macOS
/// push-button metrics.
struct PrimaryButton: View {
    let title: String
    var symbol: String? = nil
    var enabled: Bool = true
    var loading: Bool = false
    var tint: Color = Palette.accent
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if loading {
                    ProgressView().controlSize(.small).scaleEffect(0.7)
                } else if let symbol {
                    Image(systemName: symbol).font(.system(size: 11, weight: .semibold))
                }
                // The label decides the width, within bounds. A fixed 148pt
                // clipped 186 translated action titles — even the English
                // "Take Screenshots" — so the button grows to fit, and a label
                // too long for the maximum wraps onto a second line rather than
                // pushing the status text out of the run bar.
                Text(title)
                    .font(Type.headline)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, Metrics.s4)
            .padding(.vertical, 3)
            .foregroundStyle(.white)
            .frame(minWidth: Metrics.buttonMinWidth, maxWidth: Metrics.buttonMaxWidth)
            // A minimum rather than a fixed height, so a two-line label has
            // room to breathe instead of being clipped vertically.
            .frame(minHeight: Metrics.buttonHeight)
            .background(
                RoundedRectangle(cornerRadius: Metrics.radius, style: .continuous)
                    .fill(tint.opacity(enabled ? (hovering ? 0.92 : 1.0) : 0.35))
            )
        }
        .buttonStyle(.plain)
        .disabled(!enabled || loading)
        .onHover { hovering = $0 }
        .animation(Motion.quick, value: hovering)
    }
}

/// A quiet secondary action.
struct SecondaryButton: View {
    let title: String
    var symbol: String? = nil
    var compact: Bool = false
    var tint: Color = Palette.textSecondary
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let symbol {
                    Image(systemName: symbol).font(.system(size: compact ? 10 : 11, weight: .medium))
                }
                Text(title).font(compact ? Type.caption : Type.callout)
            }
            .foregroundStyle(hovering ? Palette.textPrimary : tint)
            .padding(.horizontal, compact ? Metrics.s2 : Metrics.s3)
            .frame(height: compact ? 20 : 24)
            .background(
                RoundedRectangle(cornerRadius: Metrics.radiusSmall, style: .continuous)
                    .fill(hovering ? Palette.hover : Color.primary.opacity(0.035))
            )
            .overlay(
                RoundedRectangle(cornerRadius: Metrics.radiusSmall, style: .continuous)
                    .strokeBorder(Palette.border, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(Motion.quick, value: hovering)
    }
}

/// A borderless icon button, used in toolbars and list rows.
struct IconButton: View {
    let symbol: String
    var tint: Color = Palette.textSecondary
    var size: CGFloat = 22
    var help: String? = nil
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size * 0.45, weight: .medium))
                .foregroundStyle(hovering ? Palette.textPrimary : tint)
                .frame(width: size, height: size)
                .background(
                    RoundedRectangle(cornerRadius: Metrics.radiusSmall, style: .continuous)
                        .fill(hovering ? Palette.hover : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help ?? "")
        .animation(Motion.quick, value: hovering)
    }
}

// MARK: - Drop zone

/// The empty-state drop target. Deliberately understated: a dashed rule, a
/// single glyph and one line of text.
struct DropZone: View {
    let acceptDescription: String
    let allowsMultiple: Bool
    var accent: Color = Palette.accent
    var onFiles: ([URL]) -> Void
    var onBrowse: () -> Void

    @State private var targeted = false

    var body: some View {
        VStack(spacing: Metrics.s3) {
            Image(systemName: targeted ? "arrow.down.circle.fill" : "arrow.down.circle")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(targeted ? accent : Palette.textTertiary)
                .symbolEffect(.bounce, value: targeted)

            VStack(spacing: Metrics.s1) {
                Text(targeted ? L("ui.release_to_add") : L("ui.drop_files_here"))
                    .font(Type.headline)
                    .foregroundStyle(Palette.textPrimary)
                Text(allowsMultiple ? L("ui.or_click_to_browse_multiple_files_and_fold") : L("ui.or_click_to_choose_a_single_file"))
                    .font(Type.footnote)
                    .foregroundStyle(Palette.textSecondary)
                Text(acceptDescription)
                    .font(Type.caption)
                    .foregroundStyle(Palette.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Metrics.s6)
        .background(
            RoundedRectangle(cornerRadius: Metrics.radiusLarge, style: .continuous)
                .fill(targeted ? accent.opacity(0.06) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Metrics.radiusLarge, style: .continuous)
                .strokeBorder(
                    targeted ? accent.opacity(0.6) : Palette.borderStrong,
                    style: StrokeStyle(lineWidth: 1, dash: [5, 4])
                )
        )
        .animation(Motion.snappy, value: targeted)
        .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
            Task {
                let urls = await DropLoader.load(providers)
                if !urls.isEmpty { onFiles(urls) }
            }
            return true
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onBrowse)
    }
}

/// Converts drag payloads into file URLs off the main thread.
enum DropLoader {
    static func load(_ providers: [NSItemProvider]) async -> [URL] {
        await withTaskGroup(of: URL?.self) { group in
            for provider in providers {
                group.addTask {
                    await withCheckedContinuation { cont in
                        _ = provider.loadObject(ofClass: URL.self) { url, _ in
                            cont.resume(returning: url)
                        }
                    }
                }
            }
            var urls: [URL] = []
            for await url in group { if let url { urls.append(url) } }
            return urls
        }
    }
}

// MARK: - File list

/// Compact list of staged inputs.
struct FileListView: View {
    let files: [URL]
    var accent: Color = Palette.accent
    var onRemove: (Int) -> Void
    var onClear: () -> Void
    var onReorder: ((Int, Int) -> Void)? = nil
    var onReveal: (() -> Void)? = nil
    /// Rendered inside a scroll view by the caller when true.
    var embedded: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Metrics.s2) {
                Text(L("ui.files_count_file_s", files.count))
                    .font(Type.footnote)
                    .foregroundStyle(Palette.textSecondary)
                Spacer(minLength: 0)
                if let onReveal {
                    IconButton(symbol: "folder", size: 20, help: L("ui.show_in_finder"), action: onReveal)
                }
                IconButton(symbol: "xmark", size: 20, help: L("ui.remove_all"), action: onClear)
            }
            .padding(.horizontal, Metrics.s3)
            .frame(height: 28)

            Divider().overlay(Palette.separator)

            if embedded {
                rows
            } else {
                ScrollView { rows }
                    .frame(maxHeight: 200)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: Metrics.radiusLarge, style: .continuous)
                .fill(Palette.field.opacity(0.5))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Metrics.radiusLarge, style: .continuous)
                .strokeBorder(Palette.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: Metrics.radiusLarge, style: .continuous))
    }

    private var rows: some View {
        LazyVStack(spacing: 0) {
            ForEach(Array(files.enumerated()), id: \.offset) { index, url in
                FileRow(
                    url: url, index: index, accent: accent, total: files.count,
                    onRemove: { onRemove(index) }, onReorder: onReorder
                )
                if index < files.count - 1 {
                    Divider().overlay(Palette.separator).padding(.leading, 30)
                }
            }
        }
    }
}

private struct FileRow: View {
    let url: URL
    let index: Int
    let accent: Color
    let total: Int
    let onRemove: () -> Void
    let onReorder: ((Int, Int) -> Void)?

    @State private var hovering = false

    var body: some View {
        HStack(spacing: Metrics.s2) {
            Image(systemName: FileGlyph.symbol(for: url))
                .font(.system(size: 11))
                .foregroundStyle(accent.opacity(0.9))
                .frame(width: 14)

            Text(url.lastPathComponent)
                .font(Type.callout)
                .foregroundStyle(Palette.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: Metrics.s2)

            Text(Format.bytes(FileIO.size(of: url)))
                .font(Type.mono(10))
                .foregroundStyle(Palette.textTertiary)

            if hovering {
                HStack(spacing: 1) {
                    if let onReorder {
                        IconButton(symbol: "chevron.up", size: 18, help: L("ui.move_up")) {
                            if index > 0 { onReorder(index, index - 1) }
                        }
                        .opacity(index > 0 ? 1 : 0.3)
                        IconButton(symbol: "chevron.down", size: 18, help: L("ui.move_down")) {
                            if index < total - 1 { onReorder(index, index + 1) }
                        }
                        .opacity(index < total - 1 ? 1 : 0.3)
                    }
                    IconButton(symbol: "xmark", size: 18, help: L("ui.remove"), action: onRemove)
                }
            }
        }
        .padding(.horizontal, Metrics.s3)
        .frame(height: Metrics.rowHeight)
        .background(hovering ? Palette.hover : Color.clear)
        .onHover { hovering = $0 }
        .contextMenu {
            Button(L("ui.show_in_finder")) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            Button(L("ui.copy_path")) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url.path, forType: .string)
            }
            Divider()
            Button(L("ui.remove"), role: .destructive, action: onRemove)
        }
    }
}

/// SF Symbol chosen per file kind.
enum FileGlyph {
    static func symbol(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "mp4", "mov", "mkv", "avi", "webm", "m4v", "flv", "wmv", "mpg", "mpeg", "ts":
            return "film"
        case "mp3", "m4a", "wav", "flac", "aac", "ogg", "opus":
            return "waveform"
        case "png", "jpg", "jpeg", "gif", "webp", "tiff", "bmp", "heic", "avif", "ico":
            return "photo"
        case "pdf": return "doc.richtext"
        case "doc", "docx", "rtf", "odt": return "doc.text"
        case "md", "markdown", "txt": return "text.alignleft"
        case "zip", "7z", "rar", "tar", "gz": return "archivebox"
        default: return "doc"
        }
    }
}

// MARK: - Progress

/// A thin, unobtrusive progress bar.
struct ProgressBar: View {
    let value: Double
    var tint: Color = Palette.accent
    var height: CGFloat = 3

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.09))
                Capsule()
                    .fill(tint)
                    .frame(width: max(0, min(1, value)) * geo.size.width)
                    .animation(.easeOut(duration: 0.2), value: value)
            }
        }
        .frame(height: height)
    }
}

/// Circular progress indicator for compact contexts.
struct ProgressRing: View {
    let value: Double
    var tint: Color = Palette.accent
    var size: CGFloat = 16

    var body: some View {
        ZStack {
            Circle().stroke(Color.primary.opacity(0.12), lineWidth: 2)
            Circle()
                .trim(from: 0, to: max(0.02, min(1, value)))
                .stroke(tint, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeOut(duration: 0.2), value: value)
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Small parts

/// A labelled value, used in the info panel and estimate card.
struct StatRow: View {
    let label: String
    let value: String
    var tint: Color = Palette.textPrimary

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Metrics.s2) {
            Text(label)
                .font(Type.callout)
                .foregroundStyle(Palette.textSecondary)
            Spacer(minLength: Metrics.s2)
            Text(value)
                .font(Type.mono(11.5, weight: .medium))
                .foregroundStyle(tint)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
                .lineLimit(2)
                .truncationMode(.middle)
        }
    }
}

struct EmptyState: View {
    let symbol: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: Metrics.s2) {
            Image(systemName: symbol)
                .font(.system(size: 24, weight: .light))
                .foregroundStyle(Palette.textQuaternary)
            Text(title)
                .font(Type.headline)
                .foregroundStyle(Palette.textSecondary)
            Text(message)
                .font(Type.footnote)
                .foregroundStyle(Palette.textTertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 240)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(Metrics.s6)
    }
}

/// A badge showing short status text.
struct Badge: View {
    let text: String
    var tint: Color

    var body: some View {
        Text(text)
            .font(Type.caption2.weight(.medium))
            .foregroundStyle(tint)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(tint.opacity(0.13))
            )
    }
}

// MARK: - Codec explainer

/// Explains what the selected video/audio codec is good for, so the choice is
/// informed rather than a guess. Rendered under the codec picker.
struct CodecExplainer: View {
    let codec: VideoCodec
    var audio: AudioCodec? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.s3) {
            HStack(alignment: .top, spacing: Metrics.s2) {
                Image(systemName: "info.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.accent)
                    .padding(.top, 1)
                Text(codec.summary)
                    .font(Type.footnote)
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Compact trade-off table.
            VStack(spacing: 0) {
                ForEach(Array(codec.characteristics.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .top, spacing: Metrics.s2) {
                        Text(item.0)
                            .font(Type.caption)
                            .foregroundStyle(Palette.textTertiary)
                            .frame(width: 56, alignment: .leading)
                        Text(item.1)
                            .font(Type.caption)
                            .foregroundStyle(Palette.textSecondary)
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 3)
                    .padding(.horizontal, Metrics.s2)

                    if index < codec.characteristics.count - 1 {
                        Divider().overlay(Palette.separator)
                    }
                }
            }
            .background(
                RoundedRectangle(cornerRadius: Metrics.radiusSmall, style: .continuous)
                    .fill(Palette.field.opacity(0.45))
            )
            .overlay(
                RoundedRectangle(cornerRadius: Metrics.radiusSmall, style: .continuous)
                    .strokeBorder(Palette.border, lineWidth: 1)
            )

            if let audio {
                HStack(alignment: .top, spacing: Metrics.s2) {
                    Image(systemName: "waveform")
                        .font(.system(size: 10))
                        .foregroundStyle(Palette.textTertiary)
                        .padding(.top, 1)
                    Text(L("ui.audio_audio_label_audio_summary", audio.label, audio.summary))
                        .font(Type.caption)
                        .foregroundStyle(Palette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}
