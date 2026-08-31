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
                    report("  job \(job.name): \(job.statusText)")
                    report("  log tail: \(job.log.suffix(2000))")
                }
                try? logFile?.close()
                exit(2)
            }
            let model = AppModel.shared
            model.add(urls: [pdf])
            model.start()
            while model.isRunning {
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
            watchdog.cancel()
            for job in model.jobs {
                report("job \(job.name) [\(job.engine?.label ?? "?")]: \(job.statusText) outputs=\(job.outputs.map(\.lastPathComponent))")
                if let message = job.message { report("  message: \(message)") }
                report("  log tail: \(job.log.suffix(1500))")
            }
            report(String(format: "elapsed %.1fs", Date().timeIntervalSince(started)))
            try? logFile?.close()
            exit(0)
        }
    }

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        let urls = filenames.map { URL(fileURLWithPath: $0) }
        Task { @MainActor in AppModel.shared.add(urls: urls) }
        sender.reply(toOpenOrPrint: .success)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
