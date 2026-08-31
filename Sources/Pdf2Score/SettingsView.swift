import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var settings = model.settings

        Form {
            Section("Output") {
                Picker("Location", selection: $settings.outputLocation) {
                    Text("Next to the source PDF").tag(AppSettings.OutputLocation.besideSource)
                    Text("A folder I choose").tag(AppSettings.OutputLocation.customFolder)
                }
                .pickerStyle(.radioGroup)

                HStack {
                    Text(settings.customOutputFolder?.path ?? String(localized: "Nothing chosen yet"))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                    Spacer()
                    Button("Choose…") { model.chooseOutputFolder() }
                }
                .disabled(settings.outputLocation != .customFolder)

                Toggle("Also keep the uncompressed .musicxml", isOn: $settings.keepMusicXml)
                Text("Usually the .mxl is all you need; the .musicxml is for reading the score in a text editor or putting it under version control.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Reveal in Finder when finished", isOn: $settings.revealInFinderWhenDone)
            }

            Section("Recognition") {
                Toggle("Merge multi-page PDFs into one file", isOn: $settings.mergePages)
                Text("Pages that disagree on their part layout are written out separately instead. Audiveris handles multi-page scores itself and ignores this setting.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Picker("Rendering resolution (homr only)", selection: $settings.dpi) {
                    Text("200 dpi (faster)").tag(200)
                    Text("300 dpi (recommended)").tag(300)
                    Text("400 dpi (for soft scans)").tag(400)
                }

                Toggle("Use the Apple GPU for the encoder", isOn: $settings.coremlEncoder)
                Text("homr only. The first run has to compile a CoreML model, so this pays off across many files rather than one.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .padding(.vertical, 8)
    }
}
