import Foundation

// MARK: - Log entry

/// One line in a job's activity log.
struct LogEntry: Identifiable, Sendable {
    enum Level: String, Sendable {
        case info, command, output, success, warning, error

        var symbol: String {
            switch self {
            case .info: return "circle.fill"
            case .command: return "chevron.right"
            case .output: return "text.alignleft"
            case .success: return "checkmark.circle.fill"
            case .warning: return "exclamationmark.triangle.fill"
            case .error: return "xmark.octagon.fill"
            }
        }
    }

    let id = UUID()
    let timestamp: Date
    let level: Level
    let text: String

    init(level: Level, text: String, timestamp: Date = Date()) {
        self.level = level
        self.text = text
        self.timestamp = timestamp
    }

    var timeLabel: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter.string(from: timestamp)
    }
}

// MARK: - Logger

/// Thread-safe sink that streams log lines out of worker tasks and into the UI.
/// Entries are appended from arbitrary threads, so the buffer is lock-guarded
/// and the delivery callback hops to the main actor.
final class JobLogger: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer: [LogEntry] = []
    private var truncated = 0
    private let limit: Int
    private let sink: @Sendable (LogEntry) -> Void

    init(limit: Int = 600, sink: @escaping @Sendable (LogEntry) -> Void) {
        self.limit = limit
        self.sink = sink
    }

    func log(_ level: LogEntry.Level, _ text: String) {
        // Keep the buffer bounded so a long ffmpeg run cannot exhaust memory.
        let entry = LogEntry(level: level, text: text)
        lock.lock()
        buffer.append(entry)
        if buffer.count > limit {
            let overflow = buffer.count - limit
            buffer.removeFirst(overflow)
            truncated += overflow
        }
        lock.unlock()
        sink(entry)
    }

    func info(_ text: String) { log(.info, text) }
    func command(_ text: String) { log(.command, text) }
    func output(_ text: String) { log(.output, text) }
    func success(_ text: String) { log(.success, text) }
    func warning(_ text: String) { log(.warning, text) }
    func error(_ text: String) { log(.error, text) }

    /// Multi-line helpers used for command lines and process output.
    func commandLines(_ executable: String, _ arguments: [String]) {
        command(shellLine(executable, arguments))
    }

    func outputBlock(_ text: String, level: LogEntry.Level = .output) {
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let trimmed = String(line).trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            log(level, trimmed)
        }
    }

    /// Render a command line the way a user could paste it into a terminal.
    static func shellLine(_ executable: String, _ arguments: [String]) -> String {
        ([executable] + arguments).map(quote).joined(separator: " ")
    }

    private func shellLine(_ executable: String, _ arguments: [String]) -> String {
        Self.shellLine(executable, arguments)
    }

    /// Quote only when the token would otherwise be split by the shell.
    private static func quote(_ token: String) -> String {
        let safe = CharacterSet(charactersIn:
            "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_./=:@,+")
        if token.unicodeScalars.allSatisfy({ safe.contains($0) }) { return token }
        return "'" + token.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static let silent = JobLogger { _ in }
}

// MARK: - Lifecycle

/// Log lines describing a job's start and finish. Extracted so the app queue
/// and the headless test harness emit identical, verifiable output.
enum JobLifecycle {

    static func logStart(
        _ logger: JobLogger,
        toolName: String,
        inputs: [URL],
        outputDirectory: URL,
        estimate: WorkEstimate?
    ) {
        let total = inputs.reduce(Int64(0)) { $0 + FileIO.size(of: $1) }
        logger.info(L("ui.task_started_toolname", toolName))
        logger.info(L("ui.inputs_count_file_s_format_bytes_total_tot", inputs.count, Format.bytes(total)))
        for url in inputs.prefix(10) {
            logger.info("  · \(url.lastPathComponent)  \(Format.bytes(FileIO.size(of: url)))")
        }
        if inputs.count > 10 {
            logger.info(L("ui.and_inputs_count_10_more_files", inputs.count - 10))
        }
        logger.info(L("ui.output_folder_outputdirectory_path", outputDirectory.path))
        if let estimate {
            logger.info(L("ui.estimated_estimate_sizelabel_about_estimat", estimate.sizeLabel, estimate.timeLabel)
                        + "（\(estimate.basis)）")
        }
    }

    static func logSuccess(
        _ logger: JobLogger,
        outputs: [URL],
        inputBytes: Int64,
        elapsed: TimeInterval
    ) {
        let outputBytes = outputs.reduce(Int64(0)) { $0 + FileIO.size(of: $1) }
        logger.success(L("ui.finished_outputs_count_file_s_format_bytes", outputs.count, Format.bytes(outputBytes)))
        for url in outputs.prefix(20) {
            logger.success("  → \(url.lastPathComponent)  \(Format.bytes(FileIO.size(of: url)))")
        }
        if outputs.count > 20 {
            logger.info(L("ui.and_outputs_count_20_more_files_omitted", outputs.count - 20))
        }
        if inputBytes > 0, outputBytes > 0 {
            let saved = 1 - Double(outputBytes) / Double(inputBytes)
            let verb = saved >= 0 ? L("ui.smaller") : L("ui.increased")
            logger.info(String(format: L("ui.size_by_0f"),
                               verb, abs(saved) * 100,
                               Format.bytes(inputBytes), Format.bytes(outputBytes)))
        }
        logger.info(String(format: L("ui.took_2f_s"), elapsed))
    }
}
