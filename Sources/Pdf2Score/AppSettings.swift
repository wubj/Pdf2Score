import Foundation

/// User preferences, persisted in UserDefaults and handed to worker.py as JSON.
@Observable
final class AppSettings {
    enum OutputLocation: String {
        case besideSource
        case customFolder
    }

    /// The two engines fail in different ways, so switching engines is the most
    /// useful thing to try on a score that came out badly.
    enum Engine: String, CaseIterable {
        case homr
        case audiveris

        var label: String {
            switch self {
            case .homr: return "homr"
            case .audiveris: return "Audiveris"
            }
        }

        var other: Engine { self == .homr ? .audiveris : .homr }
    }

    var engine: Engine {
        didSet { defaults.set(engine.rawValue, forKey: Keys.engine) }
    }

    var outputLocation: OutputLocation {
        didSet { defaults.set(outputLocation.rawValue, forKey: Keys.outputLocation) }
    }

    var customOutputFolder: URL? {
        didSet { defaults.set(customOutputFolder?.path, forKey: Keys.customOutputFolder) }
    }

    /// The .mxl is always written; this keeps the uncompressed XML alongside it
    /// for anyone who wants to grep or version-control the score.
    var keepMusicXml: Bool {
        didSet { defaults.set(keepMusicXml, forKey: Keys.keepMusicXml) }
    }

    var mergePages: Bool {
        didSet { defaults.set(mergePages, forKey: Keys.mergePages) }
    }

    var dpi: Int {
        didSet { defaults.set(dpi, forKey: Keys.dpi) }
    }

    var coremlEncoder: Bool {
        didSet { defaults.set(coremlEncoder, forKey: Keys.coremlEncoder) }
    }

    var revealInFinderWhenDone: Bool {
        didSet { defaults.set(revealInFinderWhenDone, forKey: Keys.revealInFinder) }
    }

    private let defaults = UserDefaults.standard

    private enum Keys {
        static let engine = "engine"
        static let outputLocation = "outputLocation"
        static let customOutputFolder = "customOutputFolder"
        static let keepMusicXml = "keepMusicXml"
        static let mergePages = "mergePages"
        static let dpi = "dpi"
        static let coremlEncoder = "coremlEncoder"
        static let revealInFinder = "revealInFinder"
    }

    init() {
        defaults.register(defaults: [
            Keys.engine: Engine.homr.rawValue,
            Keys.outputLocation: OutputLocation.besideSource.rawValue,
            Keys.keepMusicXml: false,
            Keys.mergePages: true,
            Keys.dpi: 300,
            Keys.coremlEncoder: false,
            Keys.revealInFinder: false,
        ])
        engine = Engine(rawValue: defaults.string(forKey: Keys.engine) ?? "") ?? .homr
        outputLocation = OutputLocation(
            rawValue: defaults.string(forKey: Keys.outputLocation) ?? ""
        ) ?? .besideSource
        customOutputFolder = defaults.string(forKey: Keys.customOutputFolder)
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
        keepMusicXml = defaults.bool(forKey: Keys.keepMusicXml)
        mergePages = defaults.bool(forKey: Keys.mergePages)
        dpi = defaults.integer(forKey: Keys.dpi)
        coremlEncoder = defaults.bool(forKey: Keys.coremlEncoder)
        revealInFinderWhenDone = defaults.bool(forKey: Keys.revealInFinder)
    }

    /// Which of the worker's message tables to use. The app itself ships only
    /// English and Traditional Chinese, and a Simplified Chinese system is
    /// deliberately served the Traditional strings, so this collapses to two.
    static var workerLanguage: String {
        Bundle.main.preferredLocalizations.first?.hasPrefix("zh") == true ? "zh-Hant" : "en"
    }

    /// Effective output directory, or nil to mean "next to each source PDF".
    var effectiveOutputDirectory: URL? {
        outputLocation == .customFolder ? customOutputFolder : nil
    }

    func workerOptions(engine: Engine? = nil) -> [String: Any] {
        [
            "engine": (engine ?? self.engine).rawValue,
            "language": Self.workerLanguage,
            "audiverisPath": PythonEnvironment.audiverisLauncher?.path ?? NSNull(),
            "outputDir": effectiveOutputDirectory?.path ?? NSNull(),
            "dpi": dpi,
            "merge": mergePages,
            "keepMusicXml": keepMusicXml,
            "coremlEncoder": coremlEncoder,
            "keepPreviews": false,
            "largePage": false,
        ]
    }
}
