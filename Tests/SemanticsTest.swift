import Foundation

@main struct T {
    static var failures = 0

    static func check(_ condition: Bool, _ label: String) {
        print("  \(condition ? "✓" : "✗") \(label)")
        if !condition { failures += 1 }
    }

    static func main() async {
        // 1) An image must not be classified as video.
        print("=== 1) Media kind detection ===")
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let img = root.appendingPathComponent(".test/fixtures/photo.jpg")
        let vid = root.appendingPathComponent(".test/fixtures/clip.mp4")
        let aud = root.appendingPathComponent(".test/fixtures/music.mp3")

        if let i = await MediaProbe.info(for: img) {
            check(i.kind == .image, "JPEG detected as an image (kind=\(i.kind.rawValue))")
            check(!i.hasVideo, "Images show no video group")
            check(i.hasImage, "Images show the image group")
            check(!i.hasTimeline, "Images show no duration, frame rate or bitrate")
        } else {
            check(false, "Could not read photo.jpg")
        }
        if let v = await MediaProbe.info(for: vid) {
            check(v.kind == .video && v.hasVideo && v.duration > 0,
                  "MP4 detected as video (duration \(String(format: "%.1f", v.duration))s)")
        } else {
            check(false, "Could not read clip.mp4")
        }
        if let a = await MediaProbe.info(for: aud) {
            check(a.kind == .audio && !a.hasVideo, "MP3 detected as audio")
        } else {
            check(false, "Could not read music.mp3")
        }

        // 2) Report-only tools must not demand an output folder.
        print()
        print("=== 2) Report tools need no output folder ===")
        await MainActor.run {
            let state = AppState()
            let reportTools = ["utility.hash", "utility.info", "archive.info"]
            for id in reportTools {
                guard let tool = ToolRegistry.tool(withID: id) else { continue }
                state.select(tool)
                check(!state.writesFiles, "\(tool.name) writes no files")
                check(!state.canRun || state.missingDependency == nil, "\(tool.name) is runnable")
            }
            for id in ["utility.qr", "video.convert", "image.compress"] {
                guard let tool = ToolRegistry.tool(withID: id) else { continue }
                state.select(tool)
                check(state.writesFiles, "\(tool.name) writes files")
            }
        }

        // 3) The button verb must follow the selected mode.
        print()
        print("=== 3) Button label follows the mode ===")
        await MainActor.run {
            let state = AppState()

            @MainActor func verb(_ id: String, _ key: String, _ value: String) -> String {
                guard let tool = ToolRegistry.tool(withID: id) else { return "?" }
                state.select(tool)
                if key == "dryRun" {
                    state.session.parameterValues[key] = .bool(value == "true")
                } else {
                    state.session.parameterValues[key] = .text(value)
                }
                return state.primaryActionTitle
            }

            check(verb("utility.qr", "action", "generate") == "Generate QR Code", "QR code: generate mode")
            check(verb("utility.qr", "action", "read") == "Read QR Code", "QR code: read mode")
            check(verb("doc.pdfsecurity", "action", "encrypt") == "Encrypt PDF", "PDF: encrypt mode")
            check(verb("doc.pdfsecurity", "action", "decrypt") == "Remove password", "PDF: decrypt mode")
            check(verb("video.audio.extract", "action", "extract") == "Extract audio", "Audio: extract mode")
            check(verb("video.audio.extract", "action", "remove") == "Remove audio track", "Audio: remove mode")
            check(verb("image.rename", "dryRun", "true") == "Preview Rename", "Rename: preview mode")
            check(verb("image.rename", "dryRun", "false") == "Rename", "Rename: apply mode")
        }
        print()
        print(failures == 0 ? "RESULT PASS" : "RESULT FAIL (\(failures))")
        exit(failures == 0 ? 0 : 1)
    }
}
