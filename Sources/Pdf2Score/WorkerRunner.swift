import Foundation

/// Runs `worker.py` for a whole batch and turns its output into a stream.
///
/// One process handles every file in the batch so the ~130 MB of ONNX models is
/// loaded once rather than per file.
///
/// Both pipes are drained by `readabilityHandler`, which fires on its own
/// background queue per handle. That is not an incidental choice: draining them
/// from the main actor deadlocks. Two reads on one thread run in turn, so
/// whichever pipe is not being read fills its 64 KB buffer, the worker blocks
/// writing to it, no further output arrives on the pipe that *is* being read,
/// and neither side ever moves again. It presents as a conversion stuck on its
/// first file with both processes sitting at 0% CPU.
final class WorkerRunner: @unchecked Sendable {
    enum Event {
        case starting
        case ready
        case fileStart(id: String, pages: Int)
        case pageStart(id: String, page: Int)
        case pageDone(id: String, page: Int)
        case pageError(id: String, page: Int, message: String)
        case fileDone(id: String, outputs: [URL], merged: Bool, warning: String?)
        case fileError(id: String, message: String)
        case allDone
    }

    /// Everything the worker tells us: parsed events, plus its raw log lines.
    enum Output {
        case event(Event)
        case log(String)
    }

    enum RunnerError: LocalizedError {
        case notInstalled
        case missingScript

        var errorDescription: String? {
            switch self {
            case .notInstalled:
                return String(localized: "The Python environment is not installed yet.")
            case .missingScript:
                return String(localized: "Could not find worker.py — the app may be incomplete.")
            }
        }
    }

    private let lock = NSLock()
    private var process: Process?
    private var isCancelled = false

    func cancel() {
        lock.lock()
        isCancelled = true
        let running = process
        lock.unlock()
        running?.terminate()
    }

    /// Starts the worker and returns a stream that finishes when it exits.
    func start(
        jobs: [(id: String, url: URL)],
        options: [String: Any]
    ) throws -> AsyncStream<Output> {
        guard PythonEnvironment.isInstalled else { throw RunnerError.notInstalled }
        guard let script = PythonEnvironment.workerScript else { throw RunnerError.missingScript }

        let spec: [String: Any] = [
            "jobs": jobs.map { ["id": $0.id, "pdf": $0.url.path] },
            "options": options,
        ]
        let specData = try JSONSerialization.data(withJSONObject: spec)

        let process = Process()
        process.executableURL = PythonEnvironment.pythonExecutable
        // -u keeps the worker's output unbuffered so progress stays live.
        process.arguments = ["-u", script.path]
        process.environment = Self.workerEnvironment()

        let input = Pipe()
        let events = Pipe()
        let logs = Pipe()
        process.standardInput = input
        process.standardOutput = events
        process.standardError = logs

        lock.lock()
        self.process = process
        isCancelled = false
        lock.unlock()

        try process.run()

        return AsyncStream { continuation in
            let pipesClosed = DispatchGroup()

            pipesClosed.enter()
            Self.drain(events.fileHandleForReading, onClose: { pipesClosed.leave() }) { line in
                guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                      let event = Self.parse(object)
                else { return }
                continuation.yield(.event(event))
            }

            pipesClosed.enter()
            Self.drain(logs.fileHandleForReading, onClose: { pipesClosed.leave() }) { line in
                continuation.yield(.log(String(decoding: line, as: UTF8.self) + "\n"))
            }

            // Hand over the batch and close stdin, which is what makes the
            // worker stop waiting and start.
            input.fileHandleForWriting.write(specData)
            try? input.fileHandleForWriting.close()

            pipesClosed.notify(queue: .global(qos: .utility)) { [weak self] in
                process.waitUntilExit()
                self?.lock.lock()
                let cancelled = self?.isCancelled ?? false
                self?.process = nil
                self?.lock.unlock()
                if !cancelled && process.terminationStatus != 0 {
                    let note = String(format: String(localized: "The worker exited with code %d"),
                                      process.terminationStatus)
                    continuation.yield(.log("\n" + note + "\n"))
                }
                continuation.finish()
            }

            continuation.onTermination = { [weak self] reason in
                if case .cancelled = reason { self?.cancel() }
            }
        }
    }

    /// Load both engines once and exit, without converting anything.
    ///
    /// The first launch after installing pays for macOS verifying the thousands
    /// of files in the bundle, which is slow on a build that is not notarised —
    /// minutes, for a bundle this size. Each engine is verified separately the
    /// first time its own binaries are loaded, so both are touched here, in the
    /// background, while the user is still choosing files.
    func warmUp() async {
        await warmUpWorker()
        await warmUpAudiveris()
    }

    /// Asking Audiveris for its version loads the whole JVM and its libraries,
    /// which is exactly the part that needs verifying.
    private func warmUpAudiveris() async {
        guard let launcher = PythonEnvironment.audiverisLauncher else { return }
        let process = Process()
        process.executableURL = launcher
        process.arguments = ["-version"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return }
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                process.waitUntilExit()
                continuation.resume()
            }
        }
    }

    private func warmUpWorker() async {
        guard PythonEnvironment.isInstalled, let script = PythonEnvironment.workerScript else {
            return
        }
        let process = Process()
        process.executableURL = PythonEnvironment.pythonExecutable
        process.arguments = ["-u", script.path]
        process.environment = Self.workerEnvironment()
        let input = Pipe()
        process.standardInput = input
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return }
        input.fileHandleForWriting.write(Data(#"{"jobs":[],"options":{}}"#.utf8))
        try? input.fileHandleForWriting.close()
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                process.waitUntilExit()
                continuation.resume()
            }
        }
    }

    /// Python writes __pycache__ next to the source by default, which for a
    /// distributable build lands inside the signed app bundle and breaks its
    /// seal ("a sealed resource is missing or invalid"). Send the bytecode to
    /// the user's cache directory instead: the bundle stays intact and the
    /// compile still only happens once.
    static func workerEnvironment() -> [String: String] {
        let pycache = FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Pdf2Score/pycache", isDirectory: true)
        try? FileManager.default.createDirectory(at: pycache, withIntermediateDirectories: true)
        return ProcessInfo.processInfo.environment.merging(
            ["PYTHONPYCACHEPREFIX": pycache.path], uniquingKeysWith: { _, new in new }
        )
    }

    // MARK: - Pipe reading

    /// Calls `onLine` for each newline-terminated chunk, then `onClose` at EOF.
    /// Runs entirely on the handle's own background queue.
    private static func drain(
        _ handle: FileHandle,
        onClose: @escaping () -> Void,
        onLine: @escaping (Data) -> Void
    ) {
        let buffer = LineBuffer()
        handle.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                buffer.flush(onLine)
                onClose()
                return
            }
            buffer.append(chunk, onLine)
        }
    }

    /// Accumulates partial reads and splits them on newlines. Only ever touched
    /// from one handle's serial readability queue.
    private final class LineBuffer {
        private var data = Data()

        func append(_ chunk: Data, _ onLine: (Data) -> Void) {
            data.append(chunk)
            while let newline = data.firstIndex(of: 0x0A) {
                onLine(data.subdata(in: data.startIndex..<newline))
                data.removeSubrange(data.startIndex...newline)
            }
        }

        func flush(_ onLine: (Data) -> Void) {
            guard !data.isEmpty else { return }
            onLine(data)
            data.removeAll()
        }
    }

    // MARK: - Event parsing

    private static func parse(_ object: [String: Any]) -> Event? {
        let id = object["id"] as? String ?? ""
        switch object["event"] as? String {
        case "starting":
            return .starting
        case "ready":
            return .ready
        case "file_start":
            return .fileStart(id: id, pages: object["pages"] as? Int ?? 0)
        case "page_start":
            return .pageStart(id: id, page: object["page"] as? Int ?? 0)
        case "page_done":
            return .pageDone(id: id, page: object["page"] as? Int ?? 0)
        case "page_error":
            return .pageError(
                id: id,
                page: object["page"] as? Int ?? 0,
                message: object["message"] as? String ?? ""
            )
        case "file_done":
            let paths = object["outputs"] as? [String] ?? []
            return .fileDone(
                id: id,
                outputs: paths.map { URL(fileURLWithPath: $0) },
                merged: object["merged"] as? Bool ?? false,
                warning: object["warning"] as? String
            )
        case "file_error":
            return .fileError(id: id, message: object["message"] as? String ?? String(localized: "Unknown error"))
        case "all_done":
            return .allDone
        default:
            return nil
        }
    }
}
