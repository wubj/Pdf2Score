import Foundation

/// Locations and state of the Python environment that runs homr.
///
/// Two shapes, checked in this order:
///
/// - A distributable build (`make dmg`) carries a relocatable CPython plus homr
///   and its models in `Contents/Resources/python-runtime`. Nothing is needed
///   from the host machine and there is no first-run setup.
/// - A development build has no bundled runtime and falls back to a venv in
///   Application Support, which BootstrapService creates on first launch.
enum PythonEnvironment {
    static let supportDirectory: URL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Pdf2Score", isDirectory: true)

    static var venvDirectory: URL {
        supportDirectory.appendingPathComponent("venv", isDirectory: true)
    }

    static var venvPython: URL {
        venvDirectory.appendingPathComponent("bin/python")
    }

    /// The self-contained runtime shipped inside a distributable build. When it
    /// is present the app needs nothing from the host machine — no Homebrew, no
    /// system Python, no first-run download.
    static var bundledPython: URL? {
        guard let resources = Bundle.main.resourceURL else { return nil }
        let candidate = resources.appendingPathComponent("python-runtime/bin/python3")
        return FileManager.default.isExecutableFile(atPath: candidate.path) ? candidate : nil
    }

    /// The interpreter to actually run worker.py with.
    static var pythonExecutable: URL {
        bundledPython ?? venvPython
    }

    static var markerFile: URL {
        supportDirectory.appendingPathComponent("installed.txt")
    }

    /// Interpreters we are willing to build the venv from, best first.
    /// homr 0.7.0 declares `requires-python = ">=3.11,<3.16"`.
    static let interpreterCandidates = [
        "/opt/homebrew/bin/python3.13",
        "/opt/homebrew/bin/python3.12",
        "/opt/homebrew/bin/python3.14",
        "/opt/homebrew/bin/python3.11",
        "/opt/homebrew/bin/python3",
        "/usr/local/bin/python3.13",
        "/usr/local/bin/python3",
        "/usr/bin/python3",
    ]

    // MARK: - Bundled Python sources

    /// Where worker.py and its helpers live, whether we're running from the
    /// assembled .app or straight out of `swift run` during development.
    static var scriptDirectory: URL? {
        var candidates: [URL] = []
        if let override = ProcessInfo.processInfo.environment["PDF2SCORE_PYTHON_DIR"] {
            candidates.append(URL(fileURLWithPath: override, isDirectory: true))
        }
        if let resources = Bundle.main.resourceURL {
            candidates.append(resources.appendingPathComponent("python", isDirectory: true))
        }
        candidates.append(
            URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()  // Sources/Pdf2Score
                .deletingLastPathComponent()  // Sources
                .deletingLastPathComponent()  // package root
                .appendingPathComponent("Resources/python", isDirectory: true)
        )
        return candidates.first {
            FileManager.default.fileExists(atPath: $0.appendingPathComponent("worker.py").path)
        }
    }

    /// The bundled Audiveris launcher, when this build ships the second engine.
    static var audiverisLauncher: URL? {
        var candidates: [URL] = []
        if let resources = Bundle.main.resourceURL {
            candidates.append(resources.appendingPathComponent("Audiveris.app/Contents/MacOS/Audiveris"))
        }
        // Development builds run straight out of the package.
        candidates.append(
            URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("build/audiveris-\(hostArchitecture)/Audiveris.app/Contents/MacOS/Audiveris")
        )
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    private static var hostArchitecture: String {
        #if arch(arm64)
        return "arm64"
        #else
        return "x86_64"
        #endif
    }

    static var workerScript: URL? {
        scriptDirectory?.appendingPathComponent("worker.py")
    }

    static var requirementsFile: URL? {
        scriptDirectory?.appendingPathComponent("requirements.txt")
    }

    // MARK: - Install state

    /// The marker records the requirements the venv was built from, so editing
    /// requirements.txt forces a reinstall instead of silently running stale
    /// packages.
    static var expectedMarker: String? {
        guard let requirementsFile,
              let text = try? String(contentsOf: requirementsFile, encoding: .utf8)
        else { return nil }
        return text
    }

    static var isInstalled: Bool {
        if bundledPython != nil { return true }
        guard FileManager.default.isExecutableFile(atPath: venvPython.path) else { return false }
        guard let expected = expectedMarker,
              let actual = try? String(contentsOf: markerFile, encoding: .utf8)
        else { return false }
        return expected == actual
    }

    static func writeMarker() throws {
        guard let expected = expectedMarker else { return }
        try expected.write(to: markerFile, atomically: true, encoding: .utf8)
    }

    /// First candidate interpreter that exists and reports a supported version.
    static func findInterpreter() -> String? {
        interpreterCandidates.first { path in
            guard FileManager.default.isExecutableFile(atPath: path) else { return false }
            guard let version = interpreterVersion(path) else { return false }
            return version >= (3, 11) && version < (3, 16)
        }
    }

    private static func interpreterVersion(_ path: String) -> (Int, Int)? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["-c", "import sys; print(f'{sys.version_info[0]} {sys.version_info[1]}')"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let parts = (String(data: data, encoding: .utf8) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: " ")
            .compactMap { Int($0) }
        guard parts.count == 2 else { return nil }
        return (parts[0], parts[1])
    }
}
