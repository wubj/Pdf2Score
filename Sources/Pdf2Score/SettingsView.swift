import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var settings = model.settings

        Form {
            Section("輸出") {
                Picker("存放位置", selection: $settings.outputLocation) {
                    Text("與來源 PDF 同資料夾").tag(AppSettings.OutputLocation.besideSource)
                    Text("指定資料夾").tag(AppSettings.OutputLocation.customFolder)
                }
                .pickerStyle(.radioGroup)

                HStack {
                    Text(settings.customOutputFolder?.path ?? "尚未選擇")
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                    Spacer()
                    Button("選擇…") { model.chooseOutputFolder() }
                }
                .disabled(settings.outputLocation != .customFolder)

                Toggle("同時保留未壓縮的 .musicxml", isOn: $settings.keepMusicXml)
                Text("平常只需要 .mxl；要用文字編輯器或版本控管看樂譜內容時才需要 .musicxml。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("轉檔完成後在 Finder 中顯示", isOn: $settings.revealInFinderWhenDone)
            }

            Section("辨識") {
                Toggle("把多頁 PDF 合併成單一檔案", isOn: $settings.mergePages)
                Text("各頁的聲部結構不一致時會自動改為分頁輸出。Audiveris 自己就會處理多頁，不受這個設定影響。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Picker("算圖解析度（只影響 homr）", selection: $settings.dpi) {
                    Text("200 dpi（較快）").tag(200)
                    Text("300 dpi（建議）").tag(300)
                    Text("400 dpi（掃描件模糊時）").tag(400)
                }

                Toggle("用 Apple GPU 加速 encoder", isOn: $settings.coremlEncoder)
                Text("只影響 homr。第一次執行需要編譯 CoreML 模型，檔案數量多時才划算。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .padding(.vertical, 8)
    }
}
