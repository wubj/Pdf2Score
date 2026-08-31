import Foundation

/// First-run setup: build the venv, install homr, download the ONNX models.
///
/// Roughly 300 MB of downloads, so this is a visible, cancellable, logged step
/// rather than something hidden behind a spinner.
@MainActor
@Observable
final class BootstrapService {
    enum Phase: Equatable {
        case idle
        case checkingInterpreter
        case creatingEnvironment
        case installingPackages
        case downloadingModels
        case finished
        case failed(String)

        var title: String {
            switch self {
            case .idle: return "準備中"
            case .checkingInterpreter: return "尋找可用的 Python"
            case .creatingEnvironment: return "建立 Python 環境"
            case .installingPackages: return "安裝 homr 與相依套件（約 200 MB）"
            case .downloadingModels: return "下載辨識模型（約 130 MB）"
            case .finished: return "安裝完成"
            case .failed(let message): return message
            }
        }
    }

    var phase: Phase = .idle
    var log: String = ""
    var isWorking = false

    /// Set when no usable interpreter exists, so the UI can offer the fix.
    var missingPythonHint: String?

    private var current: Process?

    func cancel() {
        current?.terminate()
    }

    func install() async {
        guard !isWorking else { return }
        isWorking = true
        missingPythonHint = nil
        log = ""
        defer { isWorking = false }

        do {
            phase = .checkingInterpreter
            guard let interpreter = PythonEnvironment.findInterpreter() else {
                missingPythonHint = "brew install python@3.13"
                phase = .failed("找不到 Python 3.11–3.15。請先安裝 Python 後再試一次。")
                return
            }
            append("使用 \(interpreter)\n")

            guard let requirements = PythonEnvironment.requirementsFile else {
                phase = .failed("找不到 requirements.txt，App 內容可能不完整。")
                return
            }

            try FileManager.default.createDirectory(
                at: PythonEnvironment.supportDirectory, withIntermediateDirectories: true
            )

            phase = .creatingEnvironment
            if !FileManager.default.isExecutableFile(atPath: PythonEnvironment.venvPython.path) {
                try await run(interpreter, ["-m", "venv", PythonEnvironment.venvDirectory.path])
            }

            phase = .installingPackages
            let python = PythonEnvironment.venvPython.path
            try await run(python, ["-m", "pip", "install", "--upgrade", "pip"])
            try await run(python, ["-m", "pip", "install", "-r", requirements.path])

            phase = .downloadingModels
            try await run(python, ["-m", "homr.main", "--init"])

            try PythonEnvironment.writeMarker()
            phase = .finished
            append("\n環境準備完成。\n")
        } catch let error as CommandError {
            phase = .failed("安裝失敗（\(error.command) 結束代碼 \(error.status)）。詳見下方紀錄。")
        } catch {
            phase = .failed("安裝失敗：\(error.localizedDescription)")
        }
    }

    // MARK: - Process helper

    private struct CommandError: Error {
        let command: String
        let status: Int32
    }

    private func run(_ executable: String, _ arguments: [String]) async throws {
        append("\n$ \(([executable] + arguments).joined(separator: " "))\n")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        // Unbuffered so pip/homr progress shows up while it happens.
        process.environment = ProcessInfo.processInfo.environment.merging(
            ["PYTHONUNBUFFERED": "1"], uniquingKeysWith: { _, new in new }
        )
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        current = process

        try process.run()
        // A broken pipe here only means the process ended; the exit status
        // below decides success or failure.
        do {
            for try await line in pipe.fileHandleForReading.bytes.lines {
                append(line + "\n")
            }
        } catch {
            append("(讀取輸出中斷：\(error.localizedDescription))\n")
        }
        process.waitUntilExit()
        current = nil

        if process.terminationStatus != 0 {
            throw CommandError(
                command: URL(fileURLWithPath: executable).lastPathComponent,
                status: process.terminationStatus
            )
        }
    }

    private func append(_ text: String) {
        log += text
        if log.count > 200_000 {
            log = String(log.suffix(150_000))
        }
    }
}
