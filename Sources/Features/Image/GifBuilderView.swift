import SwiftUI
import AppKit
import Observation

/// Per-frame state owned by the GIF editor.
@Observable
@MainActor
final class GifEditorModel {
    struct Item: Identifiable {
        let id = UUID()
        var url: URL
        var duration: Double = 0.15
        var enabled: Bool = true
    }

    var items: [Item] = []
    var width: Double = 480
    var fit: GifRecipe.FitMode = .contain
    var backgroundHex: String = "#000000"
    var loopMode: String = "forever"
    var transition: GifRecipe.Transition = .none
    var transitionFrames: Double = 4
    var colorCount: Double = 256
    var dither: Bool = false
    var reverse: Bool = false
    var uniformDuration: Double = 0.15
    /// Bumped whenever the preview should be rebuilt.
    var revision: Int = 0

    var activeItems: [Item] { items.filter(\.enabled) }

    var totalDuration: Double {
        activeItems.reduce(0) { $0 + $1.duration }
    }

    var estimatedFrames: Int {
        var count = activeItems.count
        if transition != .none, activeItems.count > 1 {
            count += (activeItems.count - 1) * Int(transitionFrames)
        }
        return count
    }

    func add(_ urls: [URL]) {
        let existing = Set(items.map(\.url.path))
        for url in urls where !existing.contains(url.path) {
            items.append(Item(url: url, duration: uniformDuration))
        }
        sync()
    }

    func remove(_ id: UUID) {
        items.removeAll { $0.id == id }
        sync()
    }

    func move(from: Int, to: Int) {
        guard items.indices.contains(from), items.indices.contains(to), from != to else { return }
        let item = items.remove(at: from)
        items.insert(item, at: to)
        sync()
    }

    func sortByName() {
        items.sort { $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent) == .orderedAscending }
        sync()
    }

    func sortByDate() {
        items.sort {
            let a = (try? $0.url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            let b = (try? $1.url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            return a < b
        }
        sync()
    }

    func shuffle() {
        items.shuffle()
        sync()
    }

    func applyUniformDuration() {
        for index in items.indices { items[index].duration = uniformDuration }
        sync()
    }

    func sync() { revision &+= 1 }

    func makeRecipe() -> GifRecipe {
        let (r, g, b) = GifEditorModel.rgb(fromHex: backgroundHex)
        let loop: Int
        switch loopMode {
        case "once": loop = 0
        case "3": loop = 2
        default: loop = 0
        }
        return GifRecipe(
            frames: activeItems.map { GifRecipe.Frame(url: $0.url, duration: max($0.duration, 0.02)) },
            width: Int(width),
            fit: fit,
            background: (r, g, b),
            loopCount: loop,
            transition: transition,
            transitionFrames: Int(transitionFrames),
            colorCount: Int(colorCount),
            dither: dither,
            reverse: reverse
        )
    }

    static func rgb(fromHex hex: String) -> (UInt8, UInt8, UInt8) {
        let color = ImageSupport.nsColor(from: hex)
        let srgb = color.usingColorSpace(.sRGB) ?? .black
        return (UInt8(srgb.redComponent * 255),
                UInt8(srgb.greenComponent * 255),
                UInt8(srgb.blueComponent * 255))
    }
}

// MARK: - Editor

struct GifBuilderEditor: View {
    @Environment(AppState.self) private var state
    @State private var model = GifEditorModel()
    @State private var previewFrames: [NSImage] = []
    @State private var previewIndex = 0
    @State private var previewTask: Task<Void, Never>?

    private var accent: Color { ToolCategory.image.accent }

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: Metrics.s5) {
            frameStrip
            settingsGrid
            previewSection
        }
        .onChange(of: state.inputs) { _, newValue in
            model.items = newValue.map { GifEditorModel.Item(url: $0, duration: model.uniformDuration) }
            model.sync()
        }
        .onChange(of: model.revision) { _, _ in
            GifRecipeBox.shared.recipe = model.makeRecipe()
            state.customEditorReady = model.activeItems.count >= 2
            schedulePreview()
        }
        .onAppear {
            model.items = state.inputs.map { GifEditorModel.Item(url: $0, duration: model.uniformDuration) }
            GifRecipeBox.shared.recipe = model.makeRecipe()
            state.customEditorReady = model.activeItems.count >= 2
            schedulePreview()
        }
        .onDisappear {
            previewTask?.cancel()
            state.customEditorReady = true
        }
    }

    // MARK: Frame strip

    private var frameStrip: some View {
        Section(title: L("ui.frames"), subtitle: L("gif.frameCount",
                             model.activeItems.count,
                             model.items.count,
                             String(format: "%.2f", model.totalDuration))) {
            VStack(alignment: .leading, spacing: 10) {
                if model.items.isEmpty {
                    Text(L("ui.add_images_and_a_reorderable_frame_list_ap"))
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.textTertiary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 24)
                } else {
                    toolbar

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(Array(model.items.enumerated()), id: \.element.id) { index, item in
                                FrameCell(
                                    item: item,
                                    index: index,
                                    accent: accent,
                                    total: model.items.count,
                                    onToggle: {
                                        model.items[index].enabled.toggle()
                                        model.sync()
                                    },
                                    onRemove: { model.remove(item.id) },
                                    onMove: { model.move(from: index, to: $0) }
                                )
                            }
                        }
                        .padding(.vertical, 4)
                        .padding(.horizontal, 2)
                    }

                    durationControls
                }
            }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 6) {
            SecondaryButton(title: L("ui.by_name"), symbol: "textformat.abc", compact: true) { model.sortByName() }
            SecondaryButton(title: L("ui.by_date"), symbol: "clock", compact: true) { model.sortByDate() }
            SecondaryButton(title: L("ui.shuffle"), symbol: "shuffle", compact: true) { model.shuffle() }
            SecondaryButton(title: L("ui.reverse"), symbol: "arrow.up.arrow.down", compact: true) {
                model.items.reverse(); model.sync()
            }
            Spacer()
            SecondaryButton(title: L("ui.enable_all"), symbol: "checkmark.circle", compact: true) {
                for i in model.items.indices { model.items[i].enabled = true }
                model.sync()
            }
        }
    }

    private var durationControls: some View {
        @Bindable var model = model
        return HStack(spacing: 12) {
            HStack(spacing: 6) {
                Text(L("ui.uniform_duration"))
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.textSecondary)
                NumberInput(value: $model.uniformDuration, range: 0.02...30, step: 0.05)
                    .frame(width: 90)
                Text(L("ui.s")).font(.system(size: 10)).foregroundStyle(Palette.textTertiary)
                SecondaryButton(title: L("ui.apply_to_all"), compact: true) { model.applyUniformDuration() }
            }
            Spacer()
            HStack(spacing: 6) {
                Text(L("ui.total_duration"))
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.textSecondary)
                Text(String(format: L("ui.2f_s"), model.totalDuration))
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(accent)
            }
            HStack(spacing: 6) {
                Text(L("ui.output_frames"))
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.textSecondary)
                Text("\(model.estimatedFrames)")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(accent)
            }
        }
    }

    // MARK: Settings

    private var settingsGrid: some View {
        @Bindable var model = model
        return Section(title: L("ui.output_settings"), symbol: "slider.horizontal.3") {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 24) {
                    VStack(alignment: .leading, spacing: 12) {
                        FieldRow(label: L("ui.canvas_width_px"),
                                 hint: L("ui.height_follows_the_first_image_s_aspect_ra")) {
                            SliderInput(value: $model.width, range: 64...1280, step: 8, ) {
                                "\(Int($0))"
                            }
                        }
                        FieldRow(label: L("ui.image_fitting")) {
                            SegmentPicker(
                                options: GifRecipe.FitMode.allCases.map { PickerOption($0.rawValue, $0.label) },
                                selection: Binding(
                                    get: { model.fit.rawValue },
                                    set: { model.fit = GifRecipe.FitMode(rawValue: $0) ?? .contain }),
                                )
                        }
                        FieldRow(label: L("ui.transition")) {
                            PopUpPicker(
                                options: GifRecipe.Transition.allCases.map { PickerOption($0.rawValue, $0.label) },
                                selection: Binding(
                                    get: { model.transition.rawValue },
                                    set: { model.transition = GifRecipe.Transition(rawValue: $0) ?? .none }),
                                )
                        }
                        if model.transition != .none {
                            FieldRow(label: L("ui.transition_frames")) {
                                SliderInput(value: $model.transitionFrames, range: 1...20, step: 1, ) {
                                    L("ui.int_0_frames", Int($0))
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity)

                    VStack(alignment: .leading, spacing: 12) {
                        FieldRow(label: L("ui.palette_colours"),
                                 hint: L("ui.fewer_colours_means_a_smaller_file_256_is")) {
                            SliderInput(value: $model.colorCount, range: 16...256, step: 8, ) {
                                "\(Int($0))"
                            }
                        }
                        FieldRow(label: L("ui.looping")) {
                            SegmentPicker(
                                options: [.init("forever", L("ui.forever")), .init("3", L("ui.3_times")), .init("once", L("ui.once"))],
                                selection: $model.loopMode, )
                        }
                        FieldRow(label: L("ui.background")) {
                            HStack(spacing: 8) {
                                LabeledTextField(placeholder: "#000000", text: $model.backgroundHex, monospaced: true)
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(Color(nsColor: ImageSupport.nsColor(from: model.backgroundHex)))
                                    .frame(width: 28, height: 28)
                                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Palette.border, lineWidth: 1))
                            }
                        }
                        HStack(spacing: 16) {
                            FieldRow(label: L("ui.reverse"), inline: true) {
                                SwitchToggle(isOn: $model.reverse)
                            }
                            Spacer()
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
    }

    // MARK: Preview

    private var previewSection: some View {
        Section(title: L("ui.preview"), subtitle: previewFrames.isEmpty ? nil : L("ui.previewframes_count_frames", previewFrames.count)) {
            VStack(spacing: 10) {
                if previewFrames.isEmpty {
                    Text(model.items.count < 2
                         ? L("ui.add_at_least_2_images_to_build_a_preview")
                         : L("ui.building_preview"))
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.textTertiary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 200)
                        .background(
                            RoundedRectangle(cornerRadius: 9)
                                .fill(Palette.field.opacity(0.5))
                        )
                } else {
                    TimelineView(.periodic(from: .now, by: previewInterval)) { timeline in
                        let index = Int(timeline.date.timeIntervalSinceReferenceDate / previewInterval) % previewFrames.count
                        Image(nsImage: previewFrames[index])
                            .resizable()
                            .interpolation(.high)
                            .aspectRatio(contentMode: .fit)
                            .frame(maxHeight: 260)
                            .frame(maxWidth: .infinity)
                            .background(
                                RoundedRectangle(cornerRadius: 9)
                                    .fill(Palette.field)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 9)
                                    .strokeBorder(Palette.border, lineWidth: 1)
                            )
                    }
                    HStack(spacing: 8) {
                        Text(L("ui.plays_at_the_real_speed_only_key_frames_ar"))
                            .font(.system(size: 10))
                            .foregroundStyle(Palette.textTertiary)
                        Spacer()
                        SecondaryButton(title: L("ui.regenerate"), symbol: "arrow.clockwise", compact: true) {
                            schedulePreview()
                        }
                    }
                }
            }
        }
    }

    private var previewInterval: Double {
        max(model.totalDuration / Double(max(previewFrames.count, 1)), 0.04)
    }

    /// Render a lightweight preview off the main thread.
    private func schedulePreview() {
        previewTask?.cancel()
        guard model.items.count >= 2 else { previewFrames = []; return }

        let recipe = model.makeRecipe()
        previewTask = Task.detached(priority: .utility) {
            let frames = GifPreviewRenderer.render(recipe: recipe, maxFrames: 24)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                previewFrames = frames
            }
        }
    }
}

// MARK: - Preview renderer

enum GifPreviewRenderer {
    /// Produce evenly spaced preview images across the animation.
    static func render(recipe: GifRecipe, maxFrames: Int) -> [NSImage] {
        var frames = recipe.frames
        if recipe.reverse { frames.reverse() }
        guard frames.count >= 2 else { return [] }

        var images: [CGImage] = []
        for frame in frames {
            if let image = ImageSupport.loadOriented(frame.url) { images.append(image) }
        }
        guard images.count >= 2 else { return [] }

        let width = min(max(recipe.width, 64), 640)
        let aspect = Double(images[0].height) / Double(max(images[0].width, 1))
        let height = max(Int((Double(width) * aspect).rounded()), 1)

        var canvases: [PixelCanvas] = []
        for image in images {
            canvases.append(PixelCanvas.render(
                image: image, width: width, height: height,
                fit: recipe.fit == .cover ? .cover : (recipe.fit == .stretch ? .stretch : .contain),
                background: recipe.background))
        }

        // Sample evenly so the preview stays responsive on long sequences.
        let step = max(canvases.count / maxFrames, 1)
        var result: [NSImage] = []
        var index = 0
        while index < canvases.count {
            if let image = canvases[index].makeCGImage() {
                result.append(NSImage(cgImage: image, size: NSSize(width: width, height: height)))
            }
            index += step
        }
        return result
    }
}

extension PixelCanvas {
    /// Convert the raw RGBA buffer back into a CGImage for display.
    func makeCGImage() -> CGImage? {
        var mutable = pixels
        return mutable.withUnsafeMutableBytes { buffer -> CGImage? in
            guard let base = buffer.baseAddress,
                  let context = CGContext(
                    data: base, width: width, height: height,
                    bitsPerComponent: 8, bytesPerRow: width * 4,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return nil }
            return context.makeImage()
        }
    }
}

// MARK: - Frame cell

private struct FrameCell: View {
    let item: GifEditorModel.Item
    let index: Int
    let accent: Color
    let total: Int
    let onToggle: () -> Void
    let onRemove: () -> Void
    let onMove: (Int) -> Void

    @State private var thumbnail: NSImage?
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 4) {
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Palette.field)
                    .frame(width: 84, height: 68)
                    .overlay {
                        if let thumbnail {
                            Image(nsImage: thumbnail)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .padding(2)
                        } else {
                            ProgressView().controlSize(.small)
                        }
                    }
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(item.enabled ? accent.opacity(0.55) : Palette.border, lineWidth: 1)
                    )
                    .opacity(item.enabled ? 1 : 0.35)

                Text("\(index + 1)")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(.black.opacity(0.6)))
                    .padding(4)

                if hovering {
                    HStack(spacing: 2) {
                        IconButton(symbol: "xmark.circle.fill", tint: Palette.danger, size: 18, action: onRemove)
                    }
                    .padding(2)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                }
            }

            Text(String(format: "%.2fs", item.duration))
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(Palette.textTertiary)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onToggle)
        .onHover { hovering = $0 }
        .contextMenu {
            Button(item.enabled ? L("ui.disable_this_frame") : L("ui.enable_this_frame"), action: onToggle)
            Divider()
            Button(L("ui.move_to_front")) { onMove(0) }
            Button(L("ui.move_to_last")) { onMove(total - 1) }
            Divider()
            Button(L("ui.remove"), role: .destructive, action: onRemove)
        }
        .task(id: item.url.path) {
            thumbnail = ThumbnailCache.shared.thumbnail(for: item.url, size: 84)
        }
    }
}

// MARK: - Slideshow editor

/// The slideshow tool shares the frame model with the GIF builder but has a
/// smaller surface: ordering, per-image duration and transitions.
struct SlideshowEditor: View {
    @Environment(AppState.self) private var state
    @State private var order: [URL] = []

    private var accent: Color { ToolCategory.video.accent }

    var body: some View {
        Section(title: L("ui.image_order"), subtitle: order.isEmpty ? nil : L("ui.order_count_images", order.count)) {
            VStack(alignment: .leading, spacing: 10) {
                if order.isEmpty {
                    Text(L("ui.add_images_to_arrange_their_order_here"))
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.textTertiary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 20)
                } else {
                    HStack(spacing: 6) {
                        SecondaryButton(title: L("ui.sort_by_name"), symbol: "textformat.abc", compact: true) {
                            order.sort { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
                            state.reorderInputs(order)
                        }
                        SecondaryButton(title: L("ui.reverse"), symbol: "arrow.up.arrow.down", compact: true) {
                            order.reverse(); state.reorderInputs(order)
                        }
                        SecondaryButton(title: L("ui.shuffle"), symbol: "shuffle", compact: true) {
                            order.shuffle(); state.reorderInputs(order)
                        }
                        Spacer()
                        Text(L("ui.use_the_arrows_in_the_input_list_to_fine_t"))
                            .font(.system(size: 10))
                            .foregroundStyle(Palette.textTertiary)
                    }

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(Array(order.enumerated()), id: \.offset) { index, url in
                                SlideshowThumb(url: url, index: index)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
        }
        .onAppear {
            order = state.inputs
            state.customEditorReady = true
        }
        .onChange(of: state.inputs) { _, newValue in order = newValue }
    }
}

private struct SlideshowThumb: View {
    let url: URL
    let index: Int
    @State private var thumbnail: NSImage?

    var body: some View {
        VStack(spacing: 3) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Palette.field)
                .frame(width: 96, height: 66)
                .overlay {
                    if let thumbnail {
                        Image(nsImage: thumbnail)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .padding(2)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                }
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Palette.border, lineWidth: 1)
                )
            Text("\(index + 1)")
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundStyle(Palette.textTertiary)
        }
        .task(id: url.path) {
            thumbnail = ThumbnailCache.shared.thumbnail(for: url, size: 96)
        }
    }
}
