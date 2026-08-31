import AppKit
import SwiftUI

/// First-run sheet: installs the Python environment homr needs.
struct BootstrapView: View {
    @Environment(AppModel.self) private var model

    private var bootstrap: BootstrapService { model.bootstrap }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("首次設定")
                    .font(.title2.bold())
                Text("Pdf2Score 需要一個獨立的 Python 環境來執行 homr 辨識引擎。這只需要做一次，之後啟動會直接跳過。")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    Label(bootstrap.phase.title, systemImage: iconName)
                        .foregroundStyle(isFailed ? Color.red : .primary)
                    if bootstrap.isWorking {
                        ProgressView().progressViewStyle(.linear)
                    }
                    if let hint = bootstrap.missingPythonHint {
                        HStack {
                            Text(hint)
                                .font(.system(.callout, design: .monospaced))
                                .textSelection(.enabled)
                            Button("複製") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(hint, forType: .string)
                            }
                            .controlSize(.small)
                        }
                    }
                    Text("下載量約 300 MB，需要網路連線。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
            }

            DisclosureGroup("安裝紀錄") {
                ScrollView {
                    Text(bootstrap.log)
                        .font(.system(.caption2, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(6)
                }
                .frame(height: 160)
                .background(Color(nsColor: .textBackgroundColor))
            }

            HStack {
                if bootstrap.isWorking {
                    Button("取消") { bootstrap.cancel() }
                }
                Spacer()
                if case .finished = bootstrap.phase {
                    Button("開始使用") { model.needsBootstrap = false }
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button(isFailed ? "重試" : "開始安裝") {
                        Task {
                            await bootstrap.install()
                            if case .finished = bootstrap.phase {
                                model.needsBootstrap = false
                            }
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(bootstrap.isWorking)
                }
            }
        }
        .padding(20)
        .frame(width: 560)
    }

    private var isFailed: Bool {
        if case .failed = bootstrap.phase { return true }
        return false
    }

    private var iconName: String {
        switch bootstrap.phase {
        case .finished: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        default: return "gearshape.2"
        }
    }
}
