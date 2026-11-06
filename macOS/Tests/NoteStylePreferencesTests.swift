import AppKit
import Testing
@testable import FoldpinCore

@Suite struct NoteStylePreferencesTests {
    @Test func legacyValuesSurviveMissingAndInvalidFields() throws {
        let old = Data(#"{"typography":{"bodyFamily":"Helvetica","codeFamily":"Menlo","bodySize":19,"codeSize":16,"lineSpacing":6},"paperOpacity":0.45,"glassOpacity":0.32,"clearGlass":true}"#.utf8)
        let value = try JSONDecoder().decode(NoteStylePreferences.self, from: old)
        #expect(value.typography.bodyFamily == "Helvetica" && value.typography.codeFamily == "Menlo")
        #expect(value.typography.bodySize == 19 && value.typography.codeSize == 16 && value.typography.lineSpacing == 6)
        #expect(value.paperOpacity == 0.45 && value.glassBalance == 0.32 && value.clearGlass)
        #expect(value.glassColorIntensity == 1)
        #expect(value.titlebarVisibility == .automatic && value.contentDensity == .standard)
        #expect(value.defaultNoteColor == .original && value.newNoteSize == .standard)
        let partial = Data(#"{"typography":{"bodyFamily":"Helvetica","bodySize":"broken","codeSize":18},"glassOpacity":0.6,"paperOpacity":-2,"clearGlass":"unknown","glassColorIntensity":9}"#.utf8)
        let recovered = try JSONDecoder().decode(NoteStylePreferences.self, from: partial)
        #expect(recovered.typography.bodyFamily == "Helvetica" && recovered.typography.bodySize == 15 && recovered.typography.codeSize == 18)
        #expect(recovered.glassBalance == 0.6 && recovered.paperOpacity == 0.2 && !recovered.clearGlass && recovered.glassColorIntensity == 1)
        let newValue = Data(#"{"glassBalance":-0.65,"glassOpacity":0.8,"paperOpacity":0.7}"#.utf8)
        let balanced = try JSONDecoder().decode(NoteStylePreferences.self, from: newValue)
        #expect(balanced.glassBalance == -0.65 && balanced.nativeGlassOpacity == 0.35)
        #expect(balanced.readingBackdropOpacity == 0)
        #expect(try JSONDecoder().decode(NoteStylePreferences.self, from: JSONEncoder().encode(balanced)).glassBalance == -0.65)
        let unknown = Data(#"{"typography":{"bodySize":21},"defaultNoteColor":"neon","contentDensity":"tiny","newNoteSize":"giant","titlebarVisibility":"hidden"}"#.utf8)
        let recoveredChoices = try JSONDecoder().decode(NoteStylePreferences.self, from: unknown)
        #expect(recoveredChoices.typography.bodySize == 21)
        #expect(recoveredChoices.defaultNoteColor == .original && recoveredChoices.contentDensity == .standard)
        #expect(recoveredChoices.newNoteSize == .standard && recoveredChoices.titlebarVisibility == .automatic)
    }

    @Test @MainActor func scopedSurfaceResetAndRestartPreserveTypography() throws {
        let domain = "Foldpin.AppearanceTests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        defaults.set("dark", forKey: "appTheme")
        let settings = NoteStyleSettings(defaults: defaults)
        settings.update {
            $0.typography.bodyFamily = "Helvetica"; $0.typography.bodySize = 20
            $0.typography.codeSize = 18; $0.typography.lineSpacing = 7
            $0.glassColorIntensity = 0; $0.glassBalance = -0.5; $0.paperOpacity = 0.4; $0.clearGlass = true
        }
        #expect(NoteStyleSettings(defaults: defaults).values == settings.values)
        let typography = settings.values.typography
        settings.update { $0.resetSurface() }
        #expect(settings.values.typography == typography)
        #expect(settings.values.glassBalance == 0 && settings.values.paperOpacity == 1)
        #expect(settings.values.nativeGlassOpacity == 1 && settings.values.readingBackdropOpacity == 0)
        #expect(settings.values.glassColorIntensity == 1 && !settings.values.clearGlass)
        #expect(defaults.string(forKey: "appTheme") == "dark")
        #expect(NoteStyleSettings(defaults: defaults).values == settings.values)
    }

    @Test @MainActor func creationPrecedenceAndScopedResetsPreserveExistingNotes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let domain = "Foldpin.AppearanceCreation." + UUID().uuidString
        defer {
            try? FileManager.default.removeItem(at: root)
            UserDefaults(suiteName: domain)?.removePersistentDomain(forName: domain)
        }
        let defaults = try #require(UserDefaults(suiteName: domain))
        let settings = NoteStyleSettings(defaults: defaults)
        settings.update {
            $0.defaultNoteColor = .blue; $0.newNoteSize = .large
            $0.titlebarVisibility = .alwaysVisible; $0.contentDensity = .comfortable
            $0.typography.bodySize = 21; $0.typography.codeSize = 19
            $0.glassBalance = 0.4
        }
        let library = NoteLibrary(directory: root, localDirectory: root.appendingPathComponent("local"),
                                  createsInitialNote: false, creationDefaults: settings)
        let normal = try #require(library.createNote())
        #expect(normal.store.document.color == .blue && normal.store.document.frame == nil && normal.store.document.initialSize == .large)
        let explicit = try #require(library.createNote(color: .pink))
        #expect(explicit.store.document.color == .pink)
        let screen = CGRect(x: 0, y: 0, width: 900, height: 650)
        let large = NoteCreationLayout.frame(in: screen, preset: settings.values.newNoteSize)
        #expect(large.size == CGSize(width: 460, height: 440))
        normal.store.setFrame(large)
        #expect(normal.store.flush())
        let copy = try #require(library.duplicateNote(normal.id))
        #expect(copy.store.document.color == .blue)
        #expect(copy.store.document.frame?.width == 460 && copy.store.document.frame?.height == 440)
        var markdown = NoteDocument(); markdown.content = NoteContent(plainText: "Imported")
        let imported = try library.importDocument(markdown, useDefaultColor: true, useDefaultSize: true)
        #expect(imported.store.document.color == .blue && imported.store.document.initialSize == .large)
        var supplied = NoteDocument(); supplied.color = .purple
        let preserved = try library.importDocument(supplied)
        #expect(preserved.store.document.color == .purple)
        let existing = normal.store.document
        settings.update { $0.defaultNoteColor = .green; $0.newNoteSize = .small }
        #expect(normal.store.document == existing)
        #expect(try library.importDocument(markdown, useDefaultColor: true, useDefaultSize: true).id == imported.id)
        #expect(imported.store.document.color == .blue && imported.store.document.initialSize == .large)
        let compactScreen = CGRect(x: 0, y: 0, width: 320, height: 245)
        let fitted = NoteCreationLayout.frame(in: compactScreen, preset: .large)
        #expect(fitted.width == 320 && fitted.height == 245 && compactScreen.contains(fitted))
        settings.update { $0.resetTitlebarAndDensity() }
        #expect(settings.values.titlebarVisibility == .automatic && settings.values.contentDensity == .standard)
        #expect(settings.values.glassBalance == 0.4 && settings.values.defaultNoteColor == .green)
        settings.update { $0.resetBodyTypography() }
        #expect(settings.values.typography.bodySize == 15 && settings.values.typography.codeSize == 19)
        settings.update { $0.resetCodeTypography() }
        #expect(settings.values.typography.codeSize == 13 && settings.values.glassBalance == 0.4)
        settings.update { $0.resetNewNoteDefaults() }
        #expect(settings.values.defaultNoteColor == .original && settings.values.newNoteSize == .standard)
        #expect(NoteStyleSettings(defaults: defaults).values == settings.values)
        #expect(normal.store.document == existing)
    }

    @Test func bothTintLayersRespectEndpoints() throws {
        for color in NoteColor.allCases {
            #expect(NotePalette.glassTint(for: color, intensity: 0) == nil)
            #expect(NotePalette.glassReadingTint(for: color, intensity: 0) == nil)
        }
        for intensity in [0.0, 0.5, 1.0] {
            #expect(NotePalette.glassTint(for: .original, intensity: intensity) == nil)
            #expect(NotePalette.glassReadingTint(for: .original, intensity: intensity) == nil)
        }
        let full = try #require(NotePalette.glassTint(for: .blue, intensity: 1))
        let half = try #require(NotePalette.glassTint(for: .blue, intensity: 0.5))
        #expect(abs(half.alphaComponent - full.alphaComponent * 0.5) < 0.0001)
        #expect(abs((NotePalette.glassReadingTint(for: .blue, intensity: 0.5)?.alphaComponent ?? 0) - 0.09) < 0.0001)
    }
}
