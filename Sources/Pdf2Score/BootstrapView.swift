import AppKit
import SwiftUI

/// First-run sheet: installs the Python environment homr needs.
struct BootstrapView: View {
    @Environment(AppModel.self) private var model

    private var bootstrap: BootstrapService { model.bootstrap }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("First-time setup")
                    .font(.title2.bold())
                Text("Pdf2Score needs its own Python environment to run the homr engine. This happens once; later launches skip it.")
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
                            Button("Copy") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(hint, forType: .string)
                            }
                            .controlSize(.small)
                        }
                    }
                    Text("About 300 MB will be downloaded. An internet connection is required.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
            }

            DisclosureGroup("Installation log") {
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
                    Button("Cancel") { bootstrap.cancel() }
                }
                Spacer()
                if case .finished = bootstrap.phase {
                    Button("Start Using It") { model.needsBootstrap = false }
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button(String(localized: isFailed ? "Retry" : "Install")) {
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
