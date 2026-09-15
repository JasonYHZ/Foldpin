import SwiftUI

struct LibraryStorageSettingsView: View {
    @ObservedObject var storage: LibraryLocationController
    var locate: (UUID) -> Void = { _ in }
    @ObservedObject private var language = LanguageSettings.shared
    private func text(_ key: String) -> String { language.bundle.localizedString(forKey: key, value: key, table: nil) }
    var body: some View {
        Form {
            Section {
                Text(text("Keep your library locally or in iCloud Drive. On another Mac, open the same library folder."))
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Section(text("Current Library")) {
                VStack(alignment: .leading, spacing: 12) {
                    Text(storage.library.directory.path).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button(text("Show in Finder")) { storage.reveal() }
                }
            }
            Section {
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
            }
            Section { LibraryUsageView(storage: storage, locate: locate) }
        }.formStyle(.grouped).environment(\.locale, language.locale)
    }
}
