import Foundation
import Observation

// MARK: - Job state

enum JobState: Equatable {
    case queued
    case running
    case finished([URL])
    /// Completed without producing files (inspection tools).
    case reported
    case failed(String)
    case cancelled

    var isTerminal: Bool {
        switch self {
        case .finished, .reported, .failed, .cancelled: return true
        default: return false
        }
    }

    var isSuccess: Bool {
        switch self {
        case .finished, .reported: return true
        default: return false
        }
    }
}

/// Breaks the initialisation cycle between `Job` and its `JobLogger`.
private final class LogBox: @unchecked Sendable {
    private let lock = NSLock()
    private var sink: (@Sendable (LogEntry) -> Void)?

    func attach(_ handler: @escaping @Sendable (LogEntry) -> Void) {
        lock.lock(); sink = handler; lock.unlock()
    }

    func deliver(_ entry: LogEntry) {
        lock.lock(); let handler = sink; lock.unlock()
        handler?(entry)
    }
}

// MARK: - Job

@Observable
final class Job: Identifiable, @unchecked Sendable {
    let id = UUID()
    let toolID: String
    let toolName: String
    let symbol: String
    let accent: ToolCategory
    let inputs: [URL]
    let startedAt = Date()

    var state: JobState = .queued
    var progress: Double = 0
    var note: String = ""
    var endedAt: Date?
    var elapsed: TimeInterval { (endedAt ?? Date()).timeIntervalSince(startedAt) }

    /// Human-readable activity log for this job.
    var entries: [LogEntry] = []
    /// Bytes of the input files, and of whatever was produced.
    var inputBytes: Int64 = 0
    var outputBytes: Int64 = 0
    /// The prediction shown before the run started.
    var estimate: WorkEstimate?

    var savedFraction: Double? {
        guard outputBytes > 0, inputBytes > 0 else { return nil }
        return 1 - Double(outputBytes) / Double(inputBytes)
    }

    @ObservationIgnored let handle = ProcessHandle()
    @ObservationIgnored let logger: JobLogger

    init(tool: Tool, inputs: [URL], estimate: WorkEstimate?) {
        self.toolID = tool.id
        self.toolName = tool.name
        self.symbol = tool.symbol
        self.accent = tool.category
        self.inputs = inputs
        self.estimate = estimate
        self.inputBytes = inputs.reduce(Int64(0)) { $0 + FileIO.size(of: $1) }

        // The logger is created before `self` is fully available, so the sink
        // captures a box that is wired up immediately afterwards.
        let box = LogBox()
        self.logger = JobLogger { entry in box.deliver(entry) }
        box.attach { [weak self] entry in
            guard let self else { return }
            Task { @MainActor in
                self.entries.append(entry)
                // Keep the in-memory log bounded for very long runs.
                if self.entries.count > 800 {
                    self.entries.removeFirst(self.entries.count - 800)
                }
            }
        }
    }

    func cancel() {
        handle.cancel()
        if !state.isTerminal { state = .cancelled }
    }
}

// MARK: - Queue

/// Serialises tool executions with bounded parallelism, exposing observable
/// progress for the UI. Work runs off the main actor; state mutates on it.
@Observable
@MainActor
final class JobQueue {
    private(set) var jobs: [Job] = []
    var maxConcurrency: Int = 2

    @ObservationIgnored private var running = 0
    @ObservationIgnored private var pending: [(Job, ToolContext, Tool)] = []
    @ObservationIgnored private var finishedOrder: [UUID] = []

    var activeCount: Int { jobs.filter { !$0.state.isTerminal }.count }
    var hasActivity: Bool { activeCount > 0 }

    func enqueue(tool: Tool, context: ToolContext, estimate: WorkEstimate? = nil) {
        let job = Job(tool: tool, inputs: context.inputs, estimate: estimate)
        jobs.insert(job, at: 0)
        pending.append((job, context, tool))
        pump()
    }

    func cancel(_ job: Job) {
        job.cancel()
        pending.removeAll { $0.0.id == job.id }
        job.endedAt = Date()
    }

    func cancelAll() {
        for job in jobs where !job.state.isTerminal { cancel(job) }
    }

    func clearFinished() {
        jobs.removeAll { $0.state.isTerminal }
    }

    private func pump() {
        while running < maxConcurrency, !pending.isEmpty {
            let (job, context, tool) = pending.removeFirst()
            guard !job.handle.isCancelled else {
                job.state = .cancelled
                job.endedAt = Date()
                continue
            }
            running += 1
            job.state = .running
            job.note = L("ui.preparing")

            JobLifecycle.logStart(
                job.logger,
                toolName: tool.name,
                inputs: context.inputs,
                outputDirectory: context.outputDirectory,
                estimate: job.estimate)

            // Progress updates arrive from arbitrary threads.
            let reporter = ProgressReporter { [weak job] fraction, note in
                Task { @MainActor in
                    guard let job else { return }
                    if fraction >= 0 { job.progress = fraction }
                    if let note { job.note = note }
                }
            }
            let liveContext = ToolContext(
                toolID: context.toolID,
                inputs: context.inputs,
                outputDirectory: context.outputDirectory,
                values: context.values,
                settings: context.settings,
                progress: reporter,
                handle: job.handle,
                logger: job.logger
            )

            Task.detached(priority: .userInitiated) {
                let outcome: JobState
                do {
                    let outputs = try await tool.run(liveContext)
                    if job.handle.isCancelled {
                        outcome = .cancelled
                    } else if outputs.isEmpty {
                        // Report-only tools legitimately produce no files; the
                        // findings were streamed to the log instead.
                        outcome = tool.writesFiles(values: liveContext.values)
                            ? .failed(L("ui.no_output_files_were_produced"))
                            : .reported
                    } else {
                        outcome = .finished(outputs)
                    }
                } catch is CancellationError {
                    outcome = .cancelled
                } catch let error as ProcessError {
                    if case .cancelled = error { outcome = .cancelled }
                    else { outcome = .failed(error.localizedDescription) }
                } catch {
                    outcome = .failed(error.localizedDescription)
                }

                await MainActor.run {
                    job.state = outcome
                    job.endedAt = Date()

                    switch outcome {
                    case .finished(let urls):
                        job.progress = 1
                        job.note = L("ui.done")
                        job.outputBytes = urls.reduce(Int64(0)) { $0 + FileIO.size(of: $1) }
                        JobLifecycle.logSuccess(
                            job.logger, outputs: urls,
                            inputBytes: job.inputBytes, elapsed: job.elapsed)
                    case .reported:
                        job.progress = 1
                        job.note = L("ui.done")
                        job.logger.success(L("ui.check_complete_see_the_log_above"))
                        job.logger.info(String(format: L("ui.took_2f_s"), job.elapsed))
                    case .failed(let message):
                        job.logger.error(message)
                    case .cancelled:
                        job.note = L("ui.cancelled")
                        job.logger.warning(L("ui.task_cancelled"))
                    default:
                        break
                    }

                    self.running -= 1
                    self.pump()
                }
            }
        }
    }
}
