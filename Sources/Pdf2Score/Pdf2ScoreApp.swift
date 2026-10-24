import AppKit
import SwiftUI

@main
struct Pdf2ScoreApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    private let model = AppModel.shared

    var body: some Scene {
        WindowGroup("Pdf2Score") {
            ContentView()
                .environment(model)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Add PDFs…") { model.chooseFiles() }
                    .keyboardShortcut("o")
            }
        }

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}

/// Handles PDFs dropped on the Dock icon or opened with "Open With…".
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        // `Pdf2Score.app/Contents/MacOS/Pdf2Score --check` reports where the app
        // thinks its Python lives — the first thing to look at when conversion
        // fails for environment reasons.
        guard CommandLine.arguments.contains("--check") else { return }
        let scripts = PythonEnvironment.scriptDirectory?.path ?? "not found"
        print("worker.py directory : \(scripts)")
        print("bundled runtime    : \(PythonEnvironment.bundledPython?.path ?? "none (using the development venv)")")
        print("python executable  : \(PythonEnvironment.pythonExecutable.path)")
        print("installed          : \(PythonEnvironment.isInstalled)")
        if PythonEnvironment.bundledPython == nil {
            print("system python      : \(PythonEnvironment.findInterpreter() ?? "none")")
        }
        exit(0)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // `Pdf2Score.app/Contents/MacOS/Pdf2Score --convert <pdf>` drives the
        // real Swift -> worker.py path from a terminal. The GUI cannot be
        // scripted here, so this is how that integration gets tested at all.
        let arguments = CommandLine.arguments
        guard let flag = arguments.firstIndex(of: "--convert"),
              arguments.index(after: flag) < arguments.endIndex
        else { return }
        let pdf = URL(fileURLWithPath: arguments[arguments.index(after: flag)])
        if let engineFlag = arguments.firstIndex(of: "--engine"),
           arguments.index(after: engineFlag) < arguments.endIndex,
           let engine = AppSettings.Engine(rawValue: arguments[arguments.index(after: engineFlag)]) {
            AppModel.shared.settings.engine = engine
        }

        // Also written to a file, so the run can be inspected when the app is
        // launched from Finder (`open -n --args --convert ...`) and stdout goes
        // nowhere — which is the only way to reproduce the app's real
        // privacy-permission context.
        let logPath = "/tmp/pdf2score-harness.log"
        FileManager.default.createFile(atPath: logPath, contents: nil)
        let logFile = FileHandle(forWritingAtPath: logPath)
        func report(_ line: String) {
            print(line)
            logFile?.write(Data((line + "\n").utf8))
        }

        Task { @MainActor in
            let started = Date()
            report("convert \(pdf.path)")
            let watchdog = Task {
                try? await Task.sleep(nanoseconds: 900 * 1_000_000_000)
                report("TIMEOUT after 900s — still running, nothing completed")
                for job in AppModel.shared.jobs {
                    report("  job \(job.name): \(job.statusText(batchRunning: AppModel.shared.isRunning))")
                    report("  log tail: \(job.log.suffix(2000))")
                }
                try? logFile?.close()
                exit(2)
            }
            let model = AppModel.shared
            // --auto deliberately never presses Convert: it verifies that
            // dropping files is enough on its own. Without it the harness
            // would call start() and the auto-start path would go untested.
            let auto = arguments.contains("--auto")
            if auto { report("auto-start mode: not calling start()") }
            model.add(urls: [pdf])
            if !auto { model.start() }
            // Auto-start is deliberately debounced, so the queue is not yet
            // running when add() returns.
            while !model.isRunning {
                if Date().timeIntervalSince(started) > 10 {
                    report("FAILED: nothing started within 10s")
                    try? logFile?.close()
                    exit(3)
                }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            // --late <pdf> adds a second file once the first batch is already
            // running. `run` snapshots the queue and refuses a second worker,
            // so without the chaining in AppModel this file is never converted
            // and simply sits in the list.
            if let flag = arguments.firstIndex(of: "--late"),
               arguments.index(after: flag) < arguments.endIndex {
                let late = URL(fileURLWithPath: arguments[arguments.index(after: flag)])
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                report("adding \(late.lastPathComponent) while the batch is running")
                model.add(urls: [late])
            }

            // --stop-after <seconds> presses Stop mid-batch and then checks
            // that the queue stays stopped. Stop has to win over the chaining
            // that picks up late arrivals, or stopping would restart the work.
            if let flag = arguments.firstIndex(of: "--stop-after"),
               arguments.index(after: flag) < arguments.endIndex,
               let delay = Double(arguments[arguments.index(after: flag)]) {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                report("pressing Stop")
                let stoppedAt = Date()
                model.cancel()
                // How long Stop takes to land matters: worker.py's SIGTERM
                // handler can only run between bytecodes, so a stop issued
                // mid-inference waits for that native call to return.
                while model.isRunning, Date().timeIntervalSince(stoppedAt) < 30 {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
                report(String(format: "Stop took %.1fs to take effect",
                              Date().timeIntervalSince(stoppedAt)))
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                let restarted = model.isRunning
                report("after Stop: isRunning=\(model.isRunning) pending=\(model.pendingJobs.count)")
                for job in model.jobs {
                    report("  \(job.name): \(job.statusText(batchRunning: model.isRunning))")
                }
                report(restarted ? "FAILED: Stop did not hold" : "OK: queue stayed stopped")
                try? logFile?.close()
                exit(restarted ? 4 : 0)
            }

            // Not just `isRunning`: the chained batch starts a moment after the
            // first one clears the flag, so a plain check can finish early.
            while model.isRunning || !model.pendingJobs.isEmpty {
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
            watchdog.cancel()
            for job in model.jobs {
                report("job \(job.name) [\(job.engine?.label ?? "?")]: \(job.statusText(batchRunning: AppModel.shared.isRunning)) outputs=\(job.outputs.map(\.lastPathComponent))")
                if let message = job.message { report("  message: \(message)") }
                report("  log tail: \(job.log.suffix(1500))")
            }
            report(String(format: "elapsed %.1fs", Date().timeIntervalSince(started)))
            try? logFile?.close()
            exit(0)
        }
    }

    /// True while the --convert harness is driving the queue. Decided at
    /// init, not in applicationDidFinishLaunching: AppKit delivers openFiles
    /// before that runs, so a flag set there would always be too late.
    private let isHarness = CommandLine.arguments.contains("--convert")

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        // AppKit hands it the harness's own path arguments at launch, which
        // silently seeds the queue and makes --late land in the first batch
        // instead of arriving mid-run. The harness owns the queue; ignore it.
        if isHarness {
            sender.reply(toOpenOrPrint: .success)
            return
        }
        let urls = filenames.map { URL(fileURLWithPath: $0) }
        Task { @MainActor in AppModel.shared.add(urls: urls) }
        sender.reply(toOpenOrPrint: .success)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
