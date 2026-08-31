import Foundation

/// One PDF queued for conversion.
@Observable
final class Job: Identifiable {
    enum State: Equatable {
        case queued
        /// The worker process is booting. On a cold start this can take about a
        /// minute, so it gets its own state rather than looking like "queued".
        case preparing
        case running
        case done
        case failed
        case cancelled
    }

    let id: String
    let url: URL

    var state: State = .queued
    var pageCount: Int = 0
    var currentPage: Int = 0
    var completedPages: Int = 0
    var outputs: [URL] = []
    /// Which engine produced this result, so the row can offer the other one.
    var engine: AppSettings.Engine?
    var message: String?
    var log: String = ""

    init(url: URL) {
        self.id = UUID().uuidString
        self.url = url
    }

    var name: String { url.lastPathComponent }

    /// nil while the page count is still unknown, so the UI can show an
    /// indeterminate bar during PDF rendering instead of a bogus 0%.
    var fraction: Double? {
        guard state != .preparing, pageCount > 0 else { return nil }
        return Double(completedPages) / Double(pageCount)
    }

    var statusText: String {
        switch state {
        case .queued:
            return String(localized: "Waiting")
        case .preparing:
            return String(localized: "Starting the recognition engine… (the first run after installing can take several minutes)")
        case .running:
            if pageCount == 0 { return String(localized: "Reading PDF…") }
            return String(format: String(localized: "Page %d of %d"), max(currentPage, 1), pageCount)
        case .done:
            return String(localized: message == nil ? "Done" : "Done, with warnings")
        case .failed:
            return String(localized: "Failed")
        case .cancelled:
            return String(localized: "Cancelled")
        }
    }

    func appendLog(_ text: String) {
        log += text
        // A runaway homr traceback shouldn't grow the log without bound.
        if log.count > 200_000 {
            log = String(log.suffix(150_000))
        }
    }

    func reset() {
        state = .queued
        pageCount = 0
        currentPage = 0
        completedPages = 0
        outputs = []
        message = nil
        log = ""
    }
}
