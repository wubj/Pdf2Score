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
            return "等待中"
        case .preparing:
            return "啟動辨識引擎…（安裝後第一次可能要好幾分鐘）"
        case .running:
            if pageCount == 0 { return "讀取 PDF…" }
            return "辨識第 \(max(currentPage, 1)) / \(pageCount) 頁"
        case .done:
            return message == nil ? "完成" : "完成（有警告）"
        case .failed:
            return "失敗"
        case .cancelled:
            return "已取消"
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
