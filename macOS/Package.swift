// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FoldpinCore",
    platforms: [.macOS("26.5")],
    products: [.library(name: "FoldpinCore", targets: ["FoldpinCore"])],
    targets: [
        .target(name: "FoldpinCore", path: "Foldpin",
                exclude: ["AppDelegate.swift", "AppearanceSettingsView.swift", "ApplicationMenuLocalization.swift",
                          "ContentView.swift", "CodeThemeSettingsView.swift", "FoldpinApp.swift", "NoteAppearance.swift",
                          "NoteEditor.swift", "NoteIconPicker.swift", "NoteActionsView.swift", "NoteWindowSurface.swift", "ShelfView.swift", "PaperWindowController.swift", "PaperPanel.swift",
                          "LibraryLocationController.swift", "LibraryStorageSettingsView.swift", "ReadinessFeatures.swift", "MCPSettingsView.swift", "MarkdownFileImportController.swift", "LibraryUsageView.swift", "Foldpin.entitlements",
                          "Assets.xcassets", "Localizable.xcstrings", "InfoPlist.xcstrings", "ThirdPartyNotices.txt"],
                sources: ["Core", "Editor", "NoteWindowDecoration.swift", "GlobalShortcut.swift", "ShortcutSettingsView.swift", "LanguageSettings.swift", "ThemeSettings.swift"],
                resources: [.copy("CodeThemes"), .copy("SyntaxResources"), .copy("EmojiResources")]),
        .testTarget(name: "FoldpinCoreTests", dependencies: ["FoldpinCore"], path: "Tests")
    ]
)
