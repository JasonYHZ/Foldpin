import SwiftUI

struct LibraryStorageSettingsView: View {
    @ObservedObject var storage: LibraryLocationController
    @ObservedObject private var language = LanguageSettings.shared
    private func text(_ key: String) -> String { language.bundle.localizedString(forKey: key, value: key, table: nil) }
    var body: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 18) {
            Text(text("Data and Storage")).font(.system(size: 23, weight: .semibold))
            Text(text("Keep your library locally or in iCloud Drive. On another Mac, open the same library folder."))
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    Label(text("Current Library"), systemImage: "folder")
                    Text(storage.library.directory.path).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button(text("Show in Finder")) { storage.reveal() }
                }.padding(8)
            }
            HStack {
                Button(text("Change Storage Location…")) { storage.chooseDestination() }
                Button(text("Open Existing Library…")) { storage.chooseExisting() }
            }.disabled(storage.isBusy)
            Button(text("Use Default Location…")) { storage.useDefault() }.disabled(storage.isBusy)
            if storage.isBusy {
                ProgressView(value: storage.progress)
                HStack { Text(text("Preparing library…")); Spacer(); Button(text("Cancel")) { storage.cancel() } }
            }
            if !storage.status.isEmpty { Text(text(storage.status)).foregroundStyle(.secondary).font(.callout) }
            if let failure = storage.failure {
                Text(failure).foregroundStyle(.red).font(.callout).textSelection(.enabled)
                Button(text("Retry")) { storage.retry() }.disabled(storage.isBusy)
            }
            Text(text("Contents and attachments are shared. Window positions and desktop visibility stay on each Mac. Concurrent edits are preserved as conflict copies."))
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }.padding(24)
        }.frame(width: 560, height: 460).environment(\.locale, language.locale)
    }
}
