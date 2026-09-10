import AppKit
import Carbon

nonisolated struct ShortcutBinding: Codable, Hashable, Sendable {
    var code: UInt16?
    var modifierBits: UInt
    init(code: UInt16?, modifiers: NSEvent.ModifierFlags = []) {
        self.code = code; modifierBits = modifiers.intersection(Self.allowedModifiers).rawValue
    }
    static let disabled = Self(code: nil)
    static let allowedModifiers: NSEvent.ModifierFlags = [.command, .control, .option, .shift]
    var modifiers: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifierBits) }
    static let keys: [UInt16: String] = [0:"a",1:"s",2:"d",3:"f",4:"h",5:"g",6:"z",7:"x",8:"c",9:"v",11:"b",12:"q",13:"w",14:"e",15:"r",16:"y",17:"t",18:"1",19:"2",20:"3",21:"4",22:"6",23:"5",24:"=",25:"9",26:"7",27:"-",28:"8",29:"0",30:"]",31:"o",32:"u",33:"[",34:"i",35:"p",37:"l",38:"j",39:"'",40:"k",41:";",42:"\\",43:",",44:"/",45:"n",46:"m",47:".",49:" ",50:"`",123:"\u{f702}",124:"\u{f703}",125:"\u{f701}",126:"\u{f700}"]
    static func named(_ key: String, _ modifiers: NSEvent.ModifierFlags) -> Self {
        guard let code = keys.first(where: { $0.value == key })?.key else { return .disabled }
        return Self(code: code, modifiers: modifiers)
    }
    var key: String { code.flatMap { Self.keys[$0] } ?? "" }
    var keycaps: [String] {
        guard let code else { return [] }
        let label = [UInt16(49):"Space",123:"←",124:"→",125:"↓",126:"↑"][code] ?? key.uppercased()
        return [(.control,"⌃"),(.option,"⌥"),(.shift,"⇧"),(.command,"⌘")]
            .compactMap { (flag: NSEvent.ModifierFlags, value: String) in modifiers.contains(flag) ? value : nil } + [label]
    }
    var carbonModifiers: UInt32 {
        var result: UInt32 = 0
        for (flag, value) in [(NSEvent.ModifierFlags.command, cmdKey),(.option,optionKey),(.control,controlKey),(.shift,shiftKey)] {
            if modifiers.contains(flag) { result |= UInt32(value) }
        }
        return result
    }
    var isValid: Bool {
        guard let code else { return modifierBits == 0 }
        return Self.keys[code] != nil && modifierBits == modifiers.intersection(Self.allowedModifiers).rawValue
            && !modifiers.intersection([.command, .control]).isEmpty
    }
    func matches(_ event: NSEvent) -> Bool {
        code == event.keyCode && modifiers == event.modifierFlags.intersection(Self.allowedModifiers)
    }
}

nonisolated enum GlobalShortcutAction: String, CaseIterable, Identifiable {
    case newNote, quickRecord, toggleNotes, shelf
    var id: String { "global." + rawValue }
    func title(bundle: Bundle) -> String {
        switch self {
        case .newNote: String(localized: "New Note", bundle: bundle)
        case .quickRecord: String(localized: "Quick Recording (Start / Finish)", bundle: bundle)
        case .toggleNotes: String(localized: "Show / Shelve Notes", bundle: bundle)
        case .shelf: String(localized: "Open Shelf", bundle: bundle)
        }
    }
}

nonisolated enum EditorShortcutAction: String, CaseIterable, Identifiable {
    case find, replace, nextMatch, previousMatch, record, image, audio, video, blockMenu, duplicateBlock, moveUp, moveDown
    var isSearch: Bool { [.find, .replace, .nextMatch, .previousMatch].contains(self) }
    var id: String { "editor." + rawValue }
    var defaultBinding: ShortcutBinding {
        switch self {
        case .find: .named("f", .command)
        case .replace: .named("f", [.command, .option])
        case .nextMatch: .named("g", .command)
        case .previousMatch: .named("g", [.command, .shift])
        case .duplicateBlock: .named("d", .command)
        case .moveUp: .init(code: 126, modifiers: [.command, .option])
        case .moveDown: .init(code: 125, modifiers: [.command, .option])
        default: .disabled
        }
    }
    func title(bundle: Bundle) -> String {
        switch self {
        case .find: String(localized: "Find in Note", bundle: bundle)
        case .replace: String(localized: "Find and Replace", bundle: bundle)
        case .nextMatch: String(localized: "Next Match", bundle: bundle)
        case .previousMatch: String(localized: "Previous Match", bundle: bundle)
        case .record: String(localized: "Record Audio", bundle: bundle)
        case .image: String(localized: "Insert Image…", bundle: bundle)
        case .audio: String(localized: "Import Audio…", bundle: bundle)
        case .video: String(localized: "Import Video…", bundle: bundle)
        case .blockMenu: String(localized: "Block actions", bundle: bundle)
        case .duplicateBlock: String(localized: "Duplicate Block", bundle: bundle)
        case .moveUp: String(localized: "Move Block Up", bundle: bundle)
        case .moveDown: String(localized: "Move Block Down", bundle: bundle)
        }
    }
}
