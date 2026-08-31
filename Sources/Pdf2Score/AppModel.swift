import AppKit
import Foundation
import UniformTypeIdentifiers

/// The conversion queue and everything the main window binds to.
@MainActor
@Observable
final class AppModel {
    /// Shared so the AppKit delegate (Dock drops, "Open With…") can reach the
    /// same queue the window is showing.
    static let shared = AppModel()

    var jobs: [Job] = []
    var selectedJobID: Job.ID?
    var isRunning = false
    var needsBootstrap = !PythonEnvironment.isInstalled

    let settings = AppSettings()
    let bootstrap = BootstrapService()

    private let runner = WorkerRunner()

    /// True while the launch-time warm-up is still running.
    private(set) var isWarmingUp = false

    var selectedJob: Job? {
        jobs.first { $0.id == selectedJobID }
    }

    var pendingJobs: [Job] {
        jobs.filter { $0.state == .queued }
    }

    var summary: String {
        let done = jobs.filter { $0.state == .done }.count
        let failed = jobs.filter { $0.state == .failed }.count
        if isPreparing {
            return String(localized: "Starting the recognition engine… the first run after installing can take several minutes")
        }
        if jobs.isEmpty {
            return String(localized: isWarmingUp ? "Preparing the recognition engine…" : "No files yet")
        }
        var parts = [
            String(format: String(localized: "%d files"), jobs.count),
            String(format: String(localized: "%d done"), done),
        ]
        if failed > 0 { parts.append(String(format: String(localized: "%d failed"), failed)) }
        return parts.joined(separator: String(localized: "summary.separator"))
    }

    /// Called once when the window appears. Skipped when a conversion is
    /// already under way — on a cold bundle both processes would queue behind
    /// the same one-time signature check, doubling the wait for no gain.
    func warmUpIfNeeded() {
        guard !isWarmingUp, !isRunning, !needsBootstrap else { return }
        isWarmingUp = true
        Task {
            await WorkerRunner().warmUp()
            isWarmingUp = false
        }
    }

    // MARK: - Queue management

    /// Accepts PDFs and folders (scanned recursively), skipping duplicates.
    func add(urls: [URL]) {
        let existing = Set(jobs.map(\.url.standardizedFileURL))
        var added: [URL] = []
        for url in urls {
            for pdf in Self.expandToPDFs(url) where !existing.contains(pdf.standardizedFileURL) {
                if !added.contains(pdf.standardizedFileURL) {
                    added.append(pdf.standardizedFileURL)
                }
            }
        }
        jobs.append(contentsOf: added.map(Job.init(url:)))
        if selectedJobID == nil { selectedJobID = jobs.first?.id }
    }

    func remove(_ job: Job) {
        jobs.removeAll { $0.id == job.id }
        if selectedJobID == job.id { selectedJobID = jobs.first?.id }
    }

    func clearFinished() {
        jobs.removeAll { $0.state == .done }
        if let selectedJobID, !jobs.contains(where: { $0.id == selectedJobID }) {
            self.selectedJobID = jobs.first?.id
        }
    }

    /// Re-runs one file through the engine that was not used last time.
    func retryWithOtherEngine(_ job: Job) {
        guard !isRunning else { return }
        let next = (job.engine ?? settings.engine).other
        job.reset()
        selectedJobID = job.id
        run([job], engine: next)
    }

    func retryFailed() {
        for job in jobs where job.state == .failed || job.state == .cancelled {
            job.reset()
        }
    }

    private static func expandToPDFs(_ url: URL) -> [URL] {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return []
        }
        if !isDirectory.boolValue {
            return url.pathExtension.lowercased() == "pdf" ? [url] : []
        }
        let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        )
        let found = enumerator?.compactMap { $0 as? URL }
            .filter { $0.pathExtension.lowercased() == "pdf" } ?? []
        return found.sorted { $0.path < $1.path }
    }

    // MARK: - Conversion

    func start() {
        run(pendingJobs, engine: settings.engine)
    }

    /// Runs an explicit set of files, optionally through the engine the user
    /// did not pick — that is what "retry with the other engine" uses.
    private func run(_ batch: [Job], engine: AppSettings.Engine) {
        guard !isRunning, !batch.isEmpty else { return }

        isRunning = true
        // The worker's startup output carries no job id, so it belongs to
        // whichever file is first in line until the worker says otherwise.
        // Without this the log pane stays empty through the whole cold start
        // and through any failure that happens before the first file begins.
        activeJobID = batch.first?.id
        batch.first?.state = .preparing
        for job in batch { job.engine = engine }
        let queued = batch
        let payload = batch.map { (id: $0.id, url: $0.url) }
        let options = settings.workerOptions(engine: engine)

        Task {
            defer { isRunning = false }
            do {
                // The stream is consumed here on the main actor, but the pipes
                // behind it are drained on background queues — see WorkerRunner.
                for await output in try runner.start(jobs: payload, options: options) {
                    switch output {
                    case .event(let event): handle(event)
                    case .log(let line): appendLog(line)
                    }
                }
            } catch {
                for job in queued where job.state != .done {
                    job.state = .failed
                    job.message = error.localizedDescription
                }
            }
            for job in queued where job.state == .running || job.state == .preparing {
                job.state = .cancelled
            }
            if settings.revealInFinderWhenDone {
                revealAllOutputs()
            }
        }
    }

    func cancel() {
        runner.cancel()
    }

    private func job(_ id: String) -> Job? {
        jobs.first { $0.id == id }
    }

    /// stderr has no job id on it, so it goes to whichever file is running.
    private var activeJobID: String?

    private func appendLog(_ line: String) {
        guard let activeJobID, let job = job(activeJobID) else { return }
        job.appendLog(line)
    }

    private func handle(_ event: WorkerRunner.Event) {
        switch event {
        case .starting, .ready:
            break

        case .fileStart(let id, let pages):
            activeJobID = id
            guard let job = job(id) else { return }
            job.state = .running
            job.pageCount = pages

        case .pageStart(let id, let page):
            activeJobID = id
            job(id)?.currentPage = page

        case .pageDone(let id, _):
            job(id)?.completedPages += 1

        case .pageError(let id, let page, let message):
            guard let job = job(id) else { return }
            job.completedPages += 1
            job.appendLog(String(format: String(localized: "Page %d failed: %@"), page, message) + "\n")

        case .fileDone(let id, let outputs, _, let warning):
            guard let job = job(id) else { return }
            job.state = .done
            job.outputs = outputs
            job.message = warning
            job.completedPages = job.pageCount

        case .fileError(let id, let message):
            guard let job = job(id) else { return }
            job.state = .failed
            job.message = message

        case .allDone:
            activeJobID = nil
        }
    }

    /// True while the worker is booting and no file has started yet, so the
    /// window can explain the wait instead of looking frozen.
    var isPreparing: Bool {
        jobs.contains { $0.state == .preparing }
    }

    // MARK: - Finder / MuseScore

    func reveal(_ job: Job) {
        guard !job.outputs.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(job.outputs)
    }

    func openInMuseScore(_ job: Job) {
        guard let musicxml = job.outputs.first(where: { $0.pathExtension == "musicxml" }) else {
            return
        }
        NSWorkspace.shared.open(musicxml)
    }

    private func revealAllOutputs() {
        let outputs = jobs.flatMap(\.outputs)
        guard !outputs.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(outputs)
    }

    func chooseOutputFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "Choose")
        panel.message = String(localized: "Choose where the converted files should go")
        if panel.runModal() == .OK, let url = panel.url {
            settings.customOutputFolder = url
            settings.outputLocation = .customFolder
        }
    }

    func chooseFiles() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.pdf, .folder]
        panel.prompt = String(localized: "Add")
        panel.message = String(localized: "Choose the PDF scores to convert — a whole folder works too")
        if panel.runModal() == .OK {
            add(urls: panel.urls)
        }
    }
}
