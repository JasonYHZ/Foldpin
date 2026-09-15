//
//  FoldpinApp.swift
//  Foldpin
//
//  Created by JasonYu on 2026/09/07.
//

import SwiftUI

@main
struct FoldpinApp: App {
    @ObservedObject private var shortcuts = ShortcutSettings.shared
    @ObservedObject private var languageSettings = LanguageSettings.shared
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Settings {
            FoldpinSettingsView(mcp: delegate.mcp, storage: delegate.storage, login: delegate.login, help: delegate.showQuickStart, feedback: delegate.showFeedback, locate: delegate.locateNote)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 900, height: 680)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .appSettings) {
                SettingsLink {
                    Text(String(localized: "Settings…", bundle: languageSettings.bundle))
                }.keyboardShortcut(",")
            }
            CommandGroup(replacing: .newItem) {
                Button(String(localized: "New Note", bundle: languageSettings.bundle)) { delegate.newPaper() }.keyboardShortcut(shortcuts.binding(NoteAction.newNote).swiftUIShortcut)
                Button(String(localized: "Open Shelf", bundle: languageSettings.bundle)) { delegate.showShelf() }
                    .keyboardShortcut(shortcuts.binding(NoteAction.shelf).swiftUIShortcut)
            }
            CommandGroup(after: .newItem) {
                Button(String(localized: "Import Markdown…", bundle: languageSettings.bundle)) { delegate.importMarkdown() }
            }
            CommandGroup(replacing: .help) {
                Button(String(localized: "User Guide", bundle: languageSettings.bundle)) { delegate.showQuickStart() }
                Button(String(localized: "Feedback…", bundle: languageSettings.bundle)) { delegate.showFeedback() }
            }
            CommandMenu(String(localized: "Find", bundle: languageSettings.bundle)) {
                ForEach([EditorShortcutAction.find, .replace, .nextMatch, .previousMatch]) { action in
                    Button(action.title(bundle: languageSettings.bundle)) { delegate.searchCurrentNote(action) }
                        .keyboardShortcut(shortcuts.binding(action).swiftUIShortcut)
                }
            }
            CommandGroup(after: .pasteboard) {
                Button(String(localized: "Paste as Plain Text", bundle: languageSettings.bundle)) {
                    NSApp.sendAction(#selector(NSTextView.pasteAsPlainText(_:)), to: nil, from: nil)
                }.keyboardShortcut("v", modifiers: [.command, .option, .shift])
            }
        }
    }
}
