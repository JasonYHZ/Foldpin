//
//  FoldpinApp.swift
//  Foldpin
//
//  Created by JasonYu on 2026/09/07.
//

import SwiftUI

@main
struct FoldpinApp: App {
    @ObservedObject private var languageSettings = LanguageSettings.shared
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Settings {
            AppearanceSettingsView()
        }
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .appSettings) {
                SettingsLink {
                    Text(String(localized: "Settings…", bundle: languageSettings.bundle))
                }.keyboardShortcut(",")
            }
            CommandGroup(replacing: .newItem) {
                Button(String(localized: "New Note", bundle: languageSettings.bundle)) { delegate.newPaper() }.keyboardShortcut("n")
                Button(String(localized: "Open Shelf", bundle: languageSettings.bundle)) { delegate.showShelf() }
            }
            CommandGroup(after: .pasteboard) {
                Button(String(localized: "Paste as Plain Text", bundle: languageSettings.bundle)) {
                    NSApp.sendAction(#selector(NSTextView.pasteAsPlainText(_:)), to: nil, from: nil)
                }.keyboardShortcut("v", modifiers: [.command, .option, .shift])
            }
        }
    }
}
