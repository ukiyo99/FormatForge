import Foundation

/// Result of a finished child process.
struct ProcessResult: Sendable {
    var exitCode: Int32
    var stdout: String
    var stderr: String
    var cancelled: Bool

    var ok: Bool { exitCode == 0 && !cancelled }
}

enum ProcessError: LocalizedError {
    case launchFailed(String)
    case missingTool(String)
    case failed(code: Int32, message: String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .launchFailed(let m): return L("enum.processerror.cancelled", m)
        case .missingTool(let t): return L("enum.processerror.cancelled.2", t)
        case .failed(let code, let message):
            let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
            // The detail is appended only when present, so the two languages
            // can phrase the prefix independently.
            let detail = trimmed.isEmpty ? "" : ":\n" + String(trimmed.suffix(600))
            return detail.isEmpty
                ? L("error.failed.short", code)
                : L("error.failed", code, detail)
        case .cancelled: return L("ui.cancelled")
        }
    }
}

/// A cancellable handle around a running child process.
final class ProcessHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var _cancelled = false

    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return _cancelled
    }

    fileprivate func attach(_ p: Process) {
        lock.lock()
        process = p
        let alreadyCancelled = _cancelled
        lock.unlock()
        if alreadyCancelled { p.terminate() }
    }

    func cancel() {
        lock.lock()
        _cancelled = true
        let p = process
        lock.unlock()
        p?.terminate()
    }
}

/// Thin, allocation-light wrapper over `Process` that streams stdout/stderr
/// incrementally so callers can parse live progress (ffmpeg `-progress`).
enum ProcessRunner {

    /// Locate an executable across the usual Homebrew + system locations.
    /// GUI apps inherit a minimal PATH, so we must probe explicitly.
    static let searchPaths = [
        "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin",
        "/usr/sbin", "/sbin", "/opt/homebrew/sbin", "/usr/local/sbin",
    ]

    /// Tools bundled inside the app (Resources/Tools). Checked first so the
    /// app works on a machine with no Homebrew at all.
    static var bundledToolsDirectory: URL? {
        guard let resources = Bundle.main.resourceURL else { return nil }
        let directory = resources.appendingPathComponent("Tools", isDirectory: true)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return nil }
        return directory
    }

    /// True when the app shipped its own copies of the external tools.
    static var isSelfContained: Bool {
        guard let directory = bundledToolsDirectory else { return false }
        return FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("ffmpeg").path)
    }

    static var cache: [String: String?] = [:]
    static let cacheLock = NSLock()

    static func locate(_ tool: String) -> String? {
        if tool.hasPrefix("/") {
            return FileManager.default.isExecutableFile(atPath: tool) ? tool : nil
        }
        cacheLock.lock()
        if let hit = cache[tool] { cacheLock.unlock(); return hit }
        cacheLock.unlock()

        var found: String?

        // 1. A copy bundled inside the app always wins: it makes the DMG work
        //    on machines without Homebrew, and guarantees a known version.
        if let directory = bundledToolsDirectory {
            let candidate = directory.appendingPathComponent(tool).path
            if FileManager.default.isExecutableFile(atPath: candidate) {
                found = candidate
            }
        }

        // 2. A user-specified path (Settings) overrides the system search.
        if found == nil, tool == "ffmpeg" || tool == "ffprobe" {
            let custom = AppSettings.shared.customFFmpegPath
            if !custom.isEmpty {
                let directory = (custom as NSString).deletingLastPathComponent
                let candidate = directory + "/" + tool
                if FileManager.default.isExecutableFile(atPath: candidate) {
                    found = candidate
                }
            }
        }

        // 3. Fall back to the system / Homebrew installations.
        if found == nil {
            for dir in searchPaths {
                let candidate = dir + "/" + tool
                if FileManager.default.isExecutableFile(atPath: candidate) {
                    found = candidate
                    break
                }
            }
        }

        cacheLock.lock(); cache[tool] = found; cacheLock.unlock()
        return found
    }

    static func exists(_ tool: String) -> Bool { locate(tool) != nil }

    /// Environment with a PATH that includes Homebrew so child tools can find
    /// their own dependencies.
    static var environment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = searchPaths.joined(separator: ":")
        env["LC_ALL"] = "en_US.UTF-8"
        env["LANG"] = "en_US.UTF-8"
        // Keep ffmpeg quiet and non-interactive.
        env["AV_LOG_FORCE_NOCOLOR"] = "1"
        return env
    }

    /// Run a tool to completion, streaming each stdout line to `onLine`.
    /// `stderr` is captured separately (ffmpeg logs there, progress on stdout).
    @discardableResult
    static func run(
        _ tool: String,
        _ arguments: [String],
        handle: ProcessHandle? = nil,
        onStdout: (@Sendable (String) -> Void)? = nil,
        onStderr: (@Sendable (String) -> Void)? = nil
    ) async throws -> ProcessResult {
        guard let path = locate(tool) else { throw ProcessError.missingTool(tool) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.environment = environment
        process.standardInput = FileHandle.nullDevice

        let outPipe = Pipe(), errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        let collector = LineCollector()
        outPipe.fileHandleForReading.readabilityHandler = { fh in
            let data = fh.availableData
            guard !data.isEmpty else { return }
            collector.append(data, isStdout: true, sink: onStdout)
        }
        errPipe.fileHandleForReading.readabilityHandler = { fh in
            let data = fh.availableData
            guard !data.isEmpty else { return }
            collector.append(data, isStdout: false, sink: onStderr)
        }

        do {
            try process.run()
        } catch {
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
            throw ProcessError.launchFailed(error.localizedDescription)
        }
        handle?.attach(process)

        // Await termination without blocking a cooperative thread.
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            process.terminationHandler = { _ in cont.resume() }
        }

        outPipe.fileHandleForReading.readabilityHandler = nil
        errPipe.fileHandleForReading.readabilityHandler = nil
        // Drain anything buffered after the handler was removed.
        collector.append(outPipe.fileHandleForReading.readDataToEndOfFile(), isStdout: true, sink: onStdout)
        collector.append(errPipe.fileHandleForReading.readDataToEndOfFile(), isStdout: false, sink: onStderr)

        let cancelled = handle?.isCancelled ?? false
        return ProcessResult(
            exitCode: process.terminationStatus,
            stdout: collector.stdout,
            stderr: collector.stderr,
            cancelled: cancelled
        )
    }

    /// Run a tool while mirroring its output into a job log.
    @discardableResult
    static func runLogged(
        _ tool: String,
        _ arguments: [String],
        handle: ProcessHandle? = nil,
        logger: JobLogger,
        onStdout: (@Sendable (String) -> Void)? = nil
    ) async throws -> ProcessResult {
        logger.commandLines(tool, arguments)
        let result = try await run(
            tool, arguments, handle: handle,
            onStdout: onStdout,
            onStderr: { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { return }
                logger.output(trimmed)
            })
        if !result.ok && !result.cancelled {
            logger.error(L("ui.tool_exited_with_code_result_exitcode", tool, result.exitCode))
        }
        return result
    }

    /// Convenience for short, non-streaming calls such as `ffprobe`.
    static func capture(_ tool: String, _ arguments: [String]) async throws -> String {
        let result = try await run(tool, arguments)
        guard result.ok else {
            throw ProcessError.failed(code: result.exitCode, message: result.stderr)
        }
        return result.stdout
    }
}

/// Thread-safe line splitter shared by the pipe readability handlers.
private final class LineCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var outBuf = Data()
    private var errBuf = Data()
    private var _stdout = ""
    private var _stderr = ""

    var stdout: String { lock.lock(); defer { lock.unlock() }; return _stdout }
    var stderr: String { lock.lock(); defer { lock.unlock() }; return _stderr }

    func append(_ data: Data, isStdout: Bool, sink: (@Sendable (String) -> Void)?) {
        guard !data.isEmpty else { return }
        lock.lock()
        if isStdout { outBuf.append(data) } else { errBuf.append(data) }

        var lines: [String] = []
        if isStdout {
            lines = Self.drain(&outBuf)
            _stdout += lines.joined(separator: "\n")
            if !lines.isEmpty { _stdout += "\n" }
        } else {
            lines = Self.drain(&errBuf)
            _stderr += lines.joined(separator: "\n")
            if !lines.isEmpty { _stderr += "\n" }
        }
        lock.unlock()

        guard let sink else { return }
        for line in lines { sink(line) }
    }

    /// Split complete lines out of the buffer, leaving a partial tail behind.
    private static func drain(_ buffer: inout Data) -> [String] {
        var lines: [String] = []
        while let idx = buffer.firstIndex(of: 0x0A) {
            let slice = buffer[buffer.startIndex..<idx]
            if let text = String(data: slice, encoding: .utf8) {
                lines.append(text.trimmingCharacters(in: CharacterSet(charactersIn: "\r")))
            }
            buffer.removeSubrange(buffer.startIndex...idx)
        }
        return lines
    }
}
