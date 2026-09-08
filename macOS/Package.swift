// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FoldpinCore",
    platforms: [.macOS("26.5")],
    products: [.library(name: "FoldpinCore", targets: ["FoldpinCore"])],
    targets: [
        .target(name: "FoldpinCore", path: "Foldpin",
                exclude: ["AppDelegate.swift", "AppearanceSettingsView.swift", "ApplicationMenuLocalization.swift",
                          "ContentView.swift", "CodeThemeSettingsView.swift", "FoldpinApp.swift", "GlobalShortcut.swift", "NoteAppearance.swift",
                          "NoteEditor.swift", "NoteWindowDecoration.swift", "NoteWindowSurface.swift", "ShelfView.swift", "PaperWindowController.swift", "PaperPanel.swift",
                          "Assets.xcassets", "Localizable.xcstrings", "ThirdPartyNotices.txt"],
                sources: ["Core", "Editor", "LanguageSettings.swift", "ThemeSettings.swift"],
                resources: [.copy("CodeThemes"), .copy("SyntaxResources")]),
        .testTarget(name: "FoldpinCoreTests", dependencies: ["FoldpinCore"], path: "Tests")
    ]
)
