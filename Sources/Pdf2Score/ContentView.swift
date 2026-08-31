import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @State private var isDropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            if model.jobs.isEmpty {
                DropPlaceholder()
            } else {
                JobList()
                Divider()
                LogPane()
            }
            Divider()
            StatusBar()
        }
        .frame(minWidth: 720, minHeight: 460)
        .task { model.warmUpIfNeeded() }
        .toolbar { Toolbar() }
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers)
            return true
        }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.accentColor, lineWidth: 3)
                    .padding(6)
                    .allowsHitTesting(false)
            }
        }
        .sheet(isPresented: Binding(
            get: { model.needsBootstrap },
            set: { _ in }
        )) {
            BootstrapView()
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) {
        for provider in providers {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in model.add(urls: [url]) }
            }
        }
    }
}

// MARK: - Empty state

private struct DropPlaceholder: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "music.note.list")
                .font(.system(size: 52, weight: .thin))
                .foregroundStyle(.secondary)
            Text("把 PDF 樂譜拖進來")
                .font(.title2)
            Text("可以一次拖入多個檔案或整個資料夾，每份 PDF 會產生一個 MXL。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("選擇檔案…") { model.chooseFiles() }
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}

// MARK: - Queue

private struct JobList: View {
    @Environment(AppModel.self) private var model

    private func retryLabel(for job: Job) -> String {
        let other = (job.engine ?? model.settings.engine).other
        return "改用 \(other.label) 重新辨識"
    }

    var body: some View {
        @Bindable var model = model
        List(selection: $model.selectedJobID) {
            ForEach(model.jobs) { job in
                JobRow(job: job)
                    .tag(job.id)
                    .contextMenu {
                        Button("在 Finder 中顯示") { model.reveal(job) }
                            .disabled(job.outputs.isEmpty)
                        Button("用 MuseScore 開啟") { model.openInMuseScore(job) }
                            .disabled(job.outputs.isEmpty)
                        Divider()
                        Button(retryLabel(for: job)) { model.retryWithOtherEngine(job) }
                            .disabled(model.isRunning || job.state == .queued)
                        Divider()
                        Button("從清單移除", role: .destructive) { model.remove(job) }
                            .disabled(model.isRunning && job.state == .running)
                    }
            }
        }
        .listStyle(.inset)
    }
}

private struct JobRow: View {
    @Bindable var job: Job

    var body: some View {
        HStack(spacing: 12) {
            StatusIcon(state: job.state)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 3) {
                Text(job.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 6) {
                    Text(job.statusText)
                    if let message = job.message {
                        Text("·").foregroundStyle(.tertiary)
                        Text(message).lineLimit(1)
                    }
                }
                .font(.caption)
                .foregroundStyle(job.state == .failed ? Color.red : .secondary)
            }

            Spacer(minLength: 12)

            if job.state == .running || job.state == .preparing {
                if let fraction = job.fraction {
                    ProgressView(value: fraction)
                        .frame(width: 120)
                } else {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 120)
                }
            } else if job.state == .done {
                Text(job.engine?.label ?? "")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct StatusIcon: View {
    let state: Job.State

    var body: some View {
        switch state {
        case .queued:
            Image(systemName: "clock").foregroundStyle(.secondary)
        case .preparing:
            Image(systemName: "gearshape.2").foregroundStyle(Color.accentColor)
        case .running:
            Image(systemName: "waveform").foregroundStyle(Color.accentColor)
        case .done:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
        case .cancelled:
            Image(systemName: "xmark.circle").foregroundStyle(.secondary)
        }
    }
}

// MARK: - Log

private struct LogPane: View {
    @Environment(AppModel.self) private var model
    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            ScrollView {
                Text(model.selectedJob?.log ?? "")
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .frame(height: 150)
            .background(Color(nsColor: .textBackgroundColor))
        } label: {
            Text("處理紀錄\(model.selectedJob.map { "（\($0.name)）" } ?? "")")
                .font(.caption)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}

// MARK: - Chrome

private struct StatusBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 10) {
            Text(model.summary)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text(outputDescription)
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("變更…") { model.chooseOutputFolder() }
                .buttonStyle(.link)
                .font(.caption)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    private var outputDescription: String {
        if let folder = model.settings.effectiveOutputDirectory {
            return "輸出到 \(folder.lastPathComponent)"
        }
        return "輸出到 PDF 所在資料夾"
    }
}

private struct Toolbar: ToolbarContent {
    @Environment(AppModel.self) private var model

    var body: some ToolbarContent {
        @Bindable var settings = model.settings

        ToolbarItemGroup {
            Button {
                model.chooseFiles()
            } label: {
                Label("加入 PDF", systemImage: "plus")
            }
            .disabled(model.isRunning)

            // The engine belongs next to the Convert button, not in Settings:
            // it is a per-batch decision, and seeing which one is selected is
            // half of knowing what to do when a result comes out wrong.
            Picker("辨識引擎", selection: $settings.engine) {
                ForEach(AppSettings.Engine.allCases, id: \.self) { engine in
                    Text(engine.label).tag(engine)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(model.isRunning)
            .help("兩個辨識引擎的強項不同：homr 對拍照或掃描較模糊的譜比較有辦法，Audiveris 對乾淨的印刷譜較穩。轉出來不理想時換另一個再試。")

            if model.isRunning {
                Button(role: .destructive) {
                    model.cancel()
                } label: {
                    Label("停止", systemImage: "stop.fill")
                }
            } else {
                Button {
                    model.start()
                } label: {
                    Label("開始轉換", systemImage: "play.fill")
                }
                .disabled(model.pendingJobs.isEmpty || model.needsBootstrap)
            }

            Menu {
                Button("重試失敗的項目") { model.retryFailed() }
                Button("清除已完成") { model.clearFinished() }
            } label: {
                Label("更多", systemImage: "ellipsis.circle")
            }
            .disabled(model.jobs.isEmpty)
        }
    }
}
