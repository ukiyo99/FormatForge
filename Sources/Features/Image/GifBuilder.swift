import Foundation
import CoreGraphics
import AppKit
import Observation

// MARK: - Recipe

/// Immutable snapshot of the GIF builder's settings, handed to the worker.
struct GifRecipe: Sendable {
    enum FitMode: String, Sendable, CaseIterable {
        case contain, cover, stretch
        var label: String {
            switch self {
            case .contain: return L("enum.fitmode.contain")
            case .cover: return L("enum.fitmode.contain.2")
            case .stretch: return L("enum.fitmode.contain.3")
            }
        }
    }

    enum Transition: String, Sendable, CaseIterable {
        case none, fade, slideLeft, slideRight, wipeLeft, wipeRight, circle

        var label: String {
            switch self {
            case .none: return L("enum.transition.none")
            case .fade: return L("enum.transition.none.2")
            case .slideLeft: return L("enum.transition.none.3")
            case .slideRight: return L("enum.transition.none.4")
            case .wipeLeft: return L("enum.transition.none.5")
            case .wipeRight: return L("enum.transition.none.6")
            case .circle: return L("enum.transition.none.7")
            }
        }
    }

    struct Frame: Sendable {
        let url: URL
        let duration: Double
    }

    var frames: [Frame]
    var width: Int
    var fit: FitMode
    var background: (UInt8, UInt8, UInt8)
    var loopCount: Int
    var transition: Transition
    var transitionFrames: Int
    var colorCount: Int
    var dither: Bool
    var reverse: Bool
}

/// Thread-safe hand-off between the SwiftUI editor and the worker task.
final class GifRecipeBox: @unchecked Sendable {
    static let shared = GifRecipeBox()
    private let lock = NSLock()
    private var stored: GifRecipe?

    var recipe: GifRecipe? {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}

// MARK: - Tool

enum MultiImageGifTool {
    static var tool: Tool { Tool(
        id: "image.gif",
        name: L("image.gif.name"),
        summary: L("image.gif.summary"),
        symbol: "rectangle.stack.badge.play",
        category: .image,
        accepts: ["png", "jpg", "jpeg", "tiff", "tif", "bmp", "heic", "webp", "gif", "avif"],
        actionTitle: L("image.gif.action"),
        parameters: [],
        hasCustomEditor: true,
        minimumInputs: 2,
        run: { context in
            guard let recipe = GifRecipeBox.shared.recipe, recipe.frames.count >= 2 else {
                throw ProcessError.failed(code: 0, message: L("ui.add_at_least_2_images"))
            }

            var frames = recipe.frames
            if recipe.reverse { frames.reverse() }

            // 1. Decode every frame.
            context.progress.report(0.02, L("ui.reading_images"))
            var images: [CGImage] = []
            for frame in frames {
                try context.checkCancelled()
                guard let image = ImageSupport.loadOriented(frame.url) else {
                    throw ProcessError.failed(code: 0, message: L("ui.could_not_read_frame_url_lastpathcomponent", frame.url.lastPathComponent))
                }
                images.append(image)
            }

            // 2. Work out the canvas geometry from the first frame.
            let width = max(recipe.width, 16)
            let aspect = Double(images[0].height) / Double(max(images[0].width, 1))
            let height = max(Int((Double(width) * aspect).rounded()), 16)

            // 3. Render frames onto the canvas.
            context.progress.report(0.08, L("ui.composing_frames"))
            var canvases: [PixelCanvas] = []
            canvases.reserveCapacity(images.count)
            for (index, image) in images.enumerated() {
                try context.checkCancelled()
                canvases.append(PixelCanvas.render(
                    image: image, width: width, height: height,
                    fit: recipe.fit == .cover ? .cover : (recipe.fit == .stretch ? .stretch : .contain),
                    background: recipe.background))
                context.progress.report(0.08 + 0.22 * Double(index + 1) / Double(images.count))
            }

            // 4. Build the final frame list, inserting transition frames.
            var output: [(canvas: PixelCanvas, delay: Double)] = []
            let transitionFrames = recipe.transition == .none ? 0 : max(recipe.transitionFrames, 1)
            let transitionShare = transitionFrames > 0
                ? min(0.4, 0.12)
                : 0

            for (index, canvas) in canvases.enumerated() {
                let baseDuration = frames[index].duration
                if index == canvases.count - 1 || transitionFrames == 0 {
                    output.append((canvas, baseDuration))
                } else {
                    // Hold most of the duration, then spend the rest on the transition.
                    let hold = baseDuration * (1 - transitionShare)
                    output.append((canvas, hold))
                    let next = canvases[index + 1]
                    let perTransition = baseDuration * transitionShare / Double(transitionFrames)
                    for step in 1...transitionFrames {
                        let progress = Double(step) / Double(transitionFrames + 1)
                        output.append((transitionCanvas(from: canvas, to: next,
                                                        recipe: recipe, progress: progress),
                                       perTransition))
                    }
                }
            }

            // 5. Quantise a palette sampled across the whole animation.
            context.progress.report(0.34, L("ui.building_palette"))
            try context.checkCancelled()
            var samples: [UInt8] = []
            let sampleBudget = 220_000
            let perFrame = max(sampleBudget / max(output.count, 1), 1)
            for entry in output {
                let pixels = entry.canvas.pixels
                let totalPixels = pixels.count / 4
                let stride = max(totalPixels / perFrame, 1)
                var i = 0
                while i < totalPixels {
                    let offset = i * 4
                    samples.append(pixels[offset])
                    samples.append(pixels[offset + 1])
                    samples.append(pixels[offset + 2])
                    samples.append(255)
                    i += stride
                }
            }
            let palette = ColorQuantizer.quantize(pixels: samples, colorCount: recipe.colorCount, sampleStride: 1)
            context.progress.report(0.45, L("ui.encoding_gif"))

            // 6. Write the GIF.
            let outputURL = context.output(ext: "gif", suffix: "")
            let scratch = try context.makeScratch()
            defer { FileIO.removeQuietly(scratch) }
            let temp = scratch.appendingPathComponent("out.gif")

            let writer = try GifWriter(
                url: temp, width: width, height: height,
                palette: palette, loopCount: recipe.loopCount)

            for (index, entry) in output.enumerated() {
                try context.checkCancelled()
                let centiseconds = max(Int((entry.delay * 100).rounded()), 2)
                writer.addFrame(pixels: entry.canvas.pixels,
                                delayCentiseconds: centiseconds,
                                dither: recipe.dither)
                if index % 5 == 0 {
                    context.progress.report(0.45 + 0.5 * Double(index + 1) / Double(output.count))
                }
            }
            writer.finish()
            context.progress.report(0.98)

            guard FileManager.default.fileExists(atPath: temp.path) else {
                throw ProcessError.failed(code: 0, message: L("ui.gif_encoding_failed"))
            }
            if let committed = try FileIO.commit(
                temp, to: outputURL, policy: context.settings.conflictPolicy) {
                context.progress.report(1)
                return [committed]
            }
            return []
        }
    ) }

    /// Produce a single intermediate frame for the chosen transition.
    private static func transitionCanvas(
        from: PixelCanvas, to: PixelCanvas, recipe: GifRecipe, progress: Double
    ) -> PixelCanvas {
        switch recipe.transition {
        case .fade: return from.blended(with: to, amount: progress)
        case .slideLeft: return from.slid(with: to, progress: progress, fromLeft: false)
        case .slideRight: return from.slid(with: to, progress: progress, fromLeft: true)
        case .wipeLeft: return from.wiped(with: to, progress: progress, fromLeft: false)
        case .wipeRight: return from.wiped(with: to, progress: progress, fromLeft: true)
        case .circle: return from.circleOpened(with: to, progress: progress)
        case .none: return from
        }
    }
}

// MARK: - Thumbnails

/// Small LRU cache of downscaled thumbnails for the frame strip.
@MainActor
final class ThumbnailCache {
    static let shared = ThumbnailCache()
    private var cache: [String: NSImage] = [:]
    private var order: [String] = []
    private let limit = 400

    func thumbnail(for url: URL, size: CGFloat = 96) -> NSImage? {
        let key = "\(url.path)#\(Int(size))"
        if let hit = cache[key] { return hit }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: size * 2,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { return nil }
        let image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        cache[key] = image
        order.append(key)
        if order.count > limit {
            let oldest = order.removeFirst()
            cache.removeValue(forKey: oldest)
        }
        return image
    }
}
