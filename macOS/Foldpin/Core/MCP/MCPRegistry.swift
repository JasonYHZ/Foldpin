import Foundation

@MainActor
struct MCPOperation {
    var name: String
    var description: String
    var permission: MCPPermission?
    var writes = false
    var confirmation = false
    var properties: [String: Any]
    var required: [String]
    var schema: [String: Any] { ["type": "object", "properties": properties, "required": required, "additionalProperties": false] }
    var tool: [String: Any] { ["name": name, "description": description, "inputSchema": schema,
        "annotations": ["readOnlyHint": !writes, "destructiveHint": confirmation, "idempotentHint": !writes, "openWorldHint": false]] }
    func validate(_ args: [String: Any]) throws {
        try Self.validate(value: args, schema: schema)
    }
    static func validate(value: Any, schema: [String: Any]) throws {
        if let choices = schema["enum"] as? [String] { guard let s = value as? String, choices.contains(s) else { throw MCPFailure("invalid_input") } }
        switch schema["type"] as? String {
        case "object":
            guard let object = value as? [String: Any] else { throw MCPFailure("invalid_input") }
            let properties = schema["properties"] as? [String: [String: Any]] ?? [:]
            for key in schema["required"] as? [String] ?? [] where object[key] == nil { throw MCPFailure("invalid_input") }
            if schema["additionalProperties"] as? Bool == false, !Set(object.keys).isSubset(of: Set(properties.keys)) { throw MCPFailure("invalid_input") }
            for (key, field) in properties { if let v = object[key] { try validate(value: v, schema: field) } }
        case "string":
            guard let text = value as? String, text.utf8.count <= (schema["maxLength"] as? Int ?? 1_048_576), text.count >= (schema["minLength"] as? Int ?? 0) else { throw MCPFailure("invalid_input") }
            if schema["format"] as? String == "uuid", UUID(uuidString: text) == nil { throw MCPFailure("invalid_input") }
        case "boolean": guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { throw MCPFailure("invalid_input") }
        case "integer", "number":
            guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite,
                  n.doubleValue >= (schema["minimum"] as? Double ?? -.greatestFiniteMagnitude), n.doubleValue <= (schema["maximum"] as? Double ?? .greatestFiniteMagnitude),
                  schema["type"] as? String != "integer" || n.doubleValue.rounded() == n.doubleValue else { throw MCPFailure("invalid_input") }
        case "array":
            guard let values = value as? [Any], values.count <= (schema["maxItems"] as? Int ?? 100), values.count >= (schema["minItems"] as? Int ?? 0) else { throw MCPFailure("invalid_input") }
            if let item = schema["items"] as? [String: Any] { for v in values { try validate(value: v, schema: item) } }
        default: throw MCPFailure("invalid_input")
        }
    }
}
@MainActor
enum MCPRegistry {
    static let version = "2025-11-25"
    static let string: [String: Any] = ["type": "string", "maxLength": 1_048_576]
    static let uuid: [String: Any] = ["type": "string", "format": "uuid"]
    static let boolean: [String: Any] = ["type": "boolean"]
    static func choice(_ values: [String]) -> [String: Any] { ["type": "string", "enum": values] }
    static func integer(_ min: Int = 0, _ max: Int = 100) -> [String: Any] { ["type": "integer", "minimum": Double(min), "maximum": Double(max)] }
    static func array(_ item: [String: Any], max: Int = 100) -> [String: Any] { ["type": "array", "items": item, "maxItems": max] }
    static func object(_ fields: [String: Any], required: [String] = []) -> [String: Any] { ["type": "object", "properties": fields, "required": required, "additionalProperties": false] }
    static let block: [String: Any] = object(["id": uuid, "kind": choice(NoteBlockKind.allCases.filter { ![.image,.audio,.video,.file].contains($0) }.map(\.rawValue)), "text": string, "isChecked": boolean, "language": choice(CodeLanguage.allCases.map(\.rawValue)), "table": object(["rows": array(array(string, max: 30), max: 100), "headerRow": boolean, "headerColumn": boolean], required: ["rows"])], required: ["kind"])
    static var operations: [MCPOperation] {
        var result: [MCPOperation] = []
        func add(_ name: String, _ description: String, _ permission: MCPPermission? = nil, write: Bool = false, confirm: Bool = false, note: Bool = false, fields: [String: Any] = [:], required: [String] = []) {
            var p = fields; p["libraryId"] = string
            var r = ["libraryId"] + required
            if note { p["noteId"] = uuid; r += ["noteId"] }
            if write { p["idempotencyKey"] = ["type": "string", "minLength": 1, "maxLength": 128]; r += ["idempotencyKey"] }
            if write && note { p["expectedRevision"] = string; r += ["expectedRevision"] }
            result.append(MCPOperation(name: "foldpin_" + name, description: description, permission: permission, writes: write, confirmation: confirm, properties: p, required: r))
        }
        add("get_capabilities", "Supported operations and limits. libraryId may be empty for discovery.")
        add("get_status", "Current library identity and service state. libraryId may be empty for discovery.")
        for name in ["list_notes", "search_notes"] { add(name, "List authorized notes, with revisions. Cursor is the next offset; pages may change when notes change.", .read, fields: ["query": string, "state": choice(["active","desktop","shelved","deleted"]), "favorite": boolean, "collectionId": uuid, "kind": choice(NoteBlockKind.allCases.map(\.rawValue)), "cursor": integer(0,1_000_000), "limit": integer(1,100)]) }
        for name in ["read_note", "read_blocks"] { add(name, "Read a page of authorized structured blocks. Does not read resource bytes.", .read, note: true, fields: ["cursor": integer(0,100_000), "limit": integer(1,100)]) }
        add("create_note", "Create one saved, collected note. Supply text OR blocks.", .create, write: true, fields: ["text": string, "blocks": array(block,max:1000), "format": choice(["text","markdown"]), "color": choice(NoteColor.allCases.map(\.rawValue)), "icon": string])
        add("duplicate_note", "Duplicate with independent note and block IDs; collected by default.", .create, write: true, note: true)
        add("update_note", "Replace all text/blocks, preserving note metadata. Supply text OR blocks.", .edit, write: true, note: true, fields: ["text": string,"blocks": array(block,max:1000),"format":choice(["text","markdown"])])
        add("insert_blocks", "Insert blocks before an anchor; omit anchor to append.", .edit, write: true, note: true, fields: ["blocks":array(block,max:1000),"beforeBlockId":uuid], required:["blocks"])
        add("update_blocks", "Replace specified blocks. Each replacement must include an existing block ID.", .edit, write: true, note: true, fields:["blocks":array(block,max:1000)],required:["blocks"])
        for name in ["move_blocks","duplicate_blocks","delete_blocks"] { add(name,"Operate on explicit blocks within one note, preserving their order.",.edit,write:true,note:true,fields:["blockIds":array(uuid),"beforeBlockId":uuid],required:["blockIds"]) }
        add("set_todo","Set checklist completion, not toggle.",.edit,write:true,note:true,fields:["blockId":uuid,"completed":boolean],required:["blockId","completed"])
        add("edit_inline_format","Set formatting in a UTF-16 range. Grapheme boundaries required.",.edit,write:true,note:true,fields:["blockId":uuid,"location":integer(0,1_000_000),"length":integer(1,1_000_000),"format":choice(["bold","italic","code","strikethrough","link","clear"]),"enabled":boolean,"url":string],required:["blockId","location","length","format"])
        add("find_in_note","Find literal case-sensitive matches with block IDs and UTF-16 ranges.",.read,note:true,fields:["query":string],required:["query"])
        add("replace_in_note","Replace literal matches in text blocks, optionally within one block.",.edit,write:true,note:true,fields:["query":string,"replacement":string,"blockId":uuid],required:["query","replacement"])
        add("edit_table","Edit cells, insert/delete rows or columns, or set headers.",.edit,write:true,note:true,fields:["blockId":uuid,"action":choice(["cell","insert_row","delete_row","insert_column","delete_column","headers"]),"row":integer(0,100),"column":integer(0,30),"text":string,"headerRow":boolean,"headerColumn":boolean],required:["blockId","action"])
        add("set_note_metadata","Set favorite, paper color, emoji icon, or remove icon.",.edit,write:true,note:true,fields:["favorite":boolean,"color":choice(NoteColor.allCases.map(\.rawValue)),"icon":string,"removeIcon":boolean])
        add("update_image","Set image caption/display width or restore original size.",.edit,write:true,note:true,fields:["blockId":uuid,"caption":string,"width":integer(40,4096),"resetSize":boolean],required:["blockId"])
        add("update_audio","Rename an audio block.",.edit,write:true,note:true,fields:["blockId":uuid,"name":string],required:["blockId","name"])
        for name in ["show_notes","shelve_notes","trash_notes","restore_notes","purge_notes"] { add(name,"Explicit targets with individual expectedRevision. Results are per-note; never cross-file atomic.",name == "purge_notes" ? .purge : name == "trash_notes" || name == "restore_notes" ? .trash : .windows,write:true,confirm:name == "purge_notes",fields:["targets":array(object(["noteId":uuid,"expectedRevision":string],required:["noteId","expectedRevision"])),"activate":boolean],required:["targets"]) }
        add("close_note","Close: collect content, move a blank note to Recently Deleted.",.windows,write:true,note:true)
        add("set_window_state","Set pin/collapse and reachable desktop geometry.",.windows,write:true,note:true,fields:["pinned":boolean,"collapsed":boolean,"frame":object(["x":["type":"number"],"y":["type":"number"],"width":integer(280,10000),"height":integer(220,10000)],required:["x","y","width","height"])])
        for name in ["arrange_windows","undo_arrangement","show_shelf","show_settings"] { add(name,"Navigate the application or arrange its desktop notes.",.windows,write:true) }
        add("list_collections","Read authorized collections and their membership.",.read)
        for name in ["create_collection","rename_collection","delete_collection","set_collection_membership"] {
            var f:[String:Any] = ["expectedRevision":string]; var r=["expectedRevision"]
            if name != "create_collection" { f["collectionId"]=uuid; r.append("collectionId") }
            if name == "create_collection" || name == "rename_collection" { f["name"]=string; r.append("name") }
            if name == "set_collection_membership" { f["noteIds"]=array(uuid); f["included"]=boolean; r += ["noteIds","included"] }
            add(name,"Update collection metadata. expectedRevision is from list_collections. Deleting a collection keeps its notes.",.collections,write:true,fields:f,required:r)
        }
        add("list_assets","List resources actually referenced by this note.",.assets,note:true)
        add("read_asset","Read at most 256 KiB as base64; only referenced resources.",.assets,note:true,fields:["blockId":uuid,"offset":integer(0,2_000_000_000),"length":integer(1,262144)],required:["blockId"])
        add("get_settings","Read allowlisted appearance and language settings.",.settings)
        add("update_settings","Set allowlisted preferences; cannot change MCP grants.",.settings,write:true,fields:["expectedRevision":string,"theme":choice(["system","light","dark"]),"language":choice(["system","zh-Hans","en"]),"appearance":choice(["paper","translucent"])],required:["expectedRevision"])
        for name in ["copy_content","copy_image","copy_block"] { add(name,"Write explicitly selected content to the system clipboard.",.clipboardWrite,write:true,note:true,fields:["blockId":uuid],required:name == "copy_content" ? [] : ["blockId"]) }
        add("paste_clipboard","Append one explicit clipboard snapshot: Markdown/text, authorized Foldpin blocks, images or local files. Editing permission is required; resource pastes also require assets permission.",.clipboardRead,write:true,note:true)
        for name in ["play_media","pause_media","seek_media","set_playback"] { add(name,"Operate on the note's media session. Supported playback parameters depend on media type.",.media,write:true,note:true,fields:["blockId":uuid,"position":["type":"number","minimum":0.0],"rate":["type":"number","minimum":0.5,"maximum":2.0]],required:["blockId"]) }
        add("start_recording","Request local approval and microphone permission, then record into this note.",.recording,write:true,confirm:true,note:true)
        for name in ["pause_recording","resume_recording"] { add(name,"Pause or resume this note's active recording without creating another session.",.recording,write:true,note:true) }
        add("stop_recording","Finish and save this note's current recording.",.recording,write:true,note:true)
        for name in ["export_notes","export_asset"] { add(name,"Export through a local save panel. Returns awaiting_user until the operation finishes.",.export,write:true,confirm:true,note:true,fields:["format":choice(["markdown","html"]),"blockId":uuid],required:name == "export_asset" ? ["blockId"] : ["format"]) }
        for name in ["open_attachment","reveal_file"] { add(name,"Open or reveal a referenced resource through macOS.",.external,write:true,confirm:true,note:true,fields:["blockId":uuid],required:["blockId"]) }
        add("import_asset","Choose a local image/audio/video/file in a system panel and append it.",.edit,write:true,confirm:true,note:true,fields:["type":choice(["image","audio","video","file"])],required:["type"])
        add("get_operation","Read this client's operation status.",fields:["operationId":uuid],required:["operationId"])
        add("cancel_operation","Cancel this client's uncommitted operation.",fields:["operationId":uuid],required:["operationId"])
        add("list_changes","List this client's undoable content changes for the current session.",.edit)
        for name in ["undo_change","redo_change"] { add(name,"Apply a revision-guarded inverse/redo for an explicit change from this client.",.edit,write:true,note:true,fields:["changeId":uuid],required:["changeId"]) }
        add("retry_storage","Retry saving a specific note without overwriting unreadable content.",.storage,write:true,note:true)
        add("quit","Request local confirmation, then quit through normal save protection.",.application,write:true,confirm:true)
        add("get_shortcuts", "Read current customizable shortcut IDs and bindings.", .settings)
        add("set_shortcut", "Set or clear one shortcut using the UI validation and registration path.", .settings, write: true, fields: ["expectedRevision":string,"shortcutId":choice(ShortcutSettings.allIDs),"keyCode":integer(0,126),"modifierBits":integer(0,2_000_000),"clear":boolean], required:["expectedRevision","shortcutId"])
        add("list_code_themes", "Read available code themes and background opacity.", .settings)
        add("set_code_theme", "Select an installed code theme or set its background opacity.", .settings, write:true, fields:["expectedRevision":string,"themeId":string,"backgroundOpacity":["type":"number","minimum":0.0,"maximum":1.0]],required:["expectedRevision"])
        add("import_code_theme", "Select and import a supported VS Code or TextMate theme using a local file panel.", .settings, write:true, confirm:true)
        add("remove_code_theme", "Remove a specific imported theme; built-in themes cannot be removed.", .settings,write:true,fields:["expectedRevision":string,"themeId":string],required:["expectedRevision","themeId"])
        add("import_markdown", "Select Markdown files and optional local resources in native panels; returns the import results.", .create,write:true,confirm:true,fields:["includeResources":boolean,"skipUnresolved":boolean])
        add("scan_storage", "Read storage totals and referenced large-resource IDs. Does not delete or download files.", .storage,write:true,fields:[:])
        add("get_library_location", "Read library identity and location-change revision without private paths.", .storage)
        add("change_library_location", "Choose a directory locally to move/open a library, or return to the default location. Existing grants remain bound to their library.", .storage,write:true,confirm:true,fields:["expectedRevision":string,"action":choice(["move","open","default"])],required:["expectedRevision","action"])
        add("get_login_status", "Read the real macOS login item state.", .settings)
        add("set_login_enabled", "Ask macOS to enable/disable launch at login. System approval may still be required.", .settings,write:true,confirm:true,fields:["enabled":boolean],required:["enabled"])
        add("show_help", "Open the editable user guide.", .application,write:true)
        add("show_feedback", "Open the local editable feedback form without sending it.", .application,write:true)
        if let i = result.firstIndex(where: { $0.name == "foldpin_export_notes" }) {
            result[i].required.removeAll { ["noteId","expectedRevision"].contains($0) }
            result[i].properties["targets"] = array(object(["noteId":uuid,"expectedRevision":string],required:["noteId","expectedRevision"]))
        }
        return result
    }
}
