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
            FoldpinSettingsView(storage: delegate.storage)
        }
        .windowResizability(.contentSize)
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

struct FoldpinSettingsView: View {
    @ObservedObject var storage: LibraryLocationController
    @State private var selectedTab = 0
    @ObservedObject private var shortcuts = ShortcutSettings.shared
    @ObservedObject private var language = LanguageSettings.shared
    var body: some View {
        TabView(selection: $selectedTab) {
            AppearanceSettingsView()
                .tabItem { Label(String(localized: "Appearance", bundle: language.bundle), systemImage: "paintpalette") }.tag(0)
            ShortcutSettingsView()
                .tabItem { Label(String(localized: "Shortcuts", bundle: language.bundle), systemImage: "keyboard") }.tag(1)
            LibraryStorageSettingsView(storage: storage)
                .tabItem { Label(String(localized: "Data and Storage", bundle: language.bundle), systemImage: "externaldrive") }.tag(2)
        }
        .onChange(of: shortcuts.showShortcuts) { _, value in if value { selectedTab = 1 } }
        .onChange(of: selectedTab) { _, value in shortcuts.showShortcuts = value == 1 }
        .onAppear { if shortcuts.showShortcuts { selectedTab = 1 } }
        .padding(8)
        .navigationTitle(String(localized: "Foldpin Settings", bundle: language.bundle))
        .environment(\.locale, language.locale)
    }
}
