import Foundation
import AppKit

/// Shared model commands; native session callbacks reuse each note's live editor.
@MainActor
final class FoldpinCommandService {
    struct Change {
        let id: UUID, client: UUID, note: UUID
        let library: String
        let before: NoteContent, after: NoteContent
        var revision: String
        var undone = false
    }
    let library: () -> NoteLibrary
    let journal: MCPJournal
    var native: (@MainActor (String, [String: Any], MCPGrant) async throws -> [String: Any])?
    var isBusy: ((UUID?) -> Bool)?
    var commitContent: ((NoteLibrary.Entry, NoteContent) throws -> Void)?
    var didChange: (() -> Void)?
    var validateGrant: ((MCPGrant) -> Bool)?
    var requestConfirmation: ((UUID, String, [String: Any], MCPGrant) -> Void)?
    var changes: [UUID: Change] = [:]
    private var pending: [UUID: (String, [String: Any], MCPGrant, String)] = [:]
    private var states: [UUID: (UUID, [String: Any])] = [:]
    private var executing = false
    private var activeOperation: UUID?
    private var activeReceiptKey: String?
    var cancelNative: (() -> Void)?
    func ensureCurrent(_ grant: MCPGrant, args: [String: Any]) throws {
        if let activeOperation, cancelled.contains(activeOperation) { throw MCPFailure("cancelled") }
        try preflight(args, grant)
    }
    private var cancelled: Set<UUID> = []
    init(library: @escaping () -> NoteLibrary, journal: MCPJournal) { self.library = library; self.journal = journal }
    var libraryID: String { library().path.manifest?.id.uuidString ?? (try? MCPJSON.hash(library().directory.standardizedFileURL.path)) ?? "unavailable" }
    func collections() -> NoteCollections { NoteCollections(directory: library().directory, libraryPath: library().path) }
    func allowed(_ id: UUID, _ grant: MCPGrant) -> Bool {
        guard grant.libraryID == libraryID else { return false }
        if grant.noteIDs == nil { return true }
        if grant.noteIDs!.contains(id) { return true }
        return collections().collections.contains { grant.collectionIDs.contains($0.id) && $0.members.contains(id) }
    }
    func entry(_ id: UUID, _ grant: MCPGrant, deleted: Bool = true) throws -> NoteLibrary.Entry {
        guard allowed(id,grant), let entry = (library().entries + (deleted ? library().deletedEntries : [])).first(where: { $0.id == id }),
              entry.store.document.deletedAt == nil || grant.permissions.contains(.trash) || grant.permissions.contains(.purge) else { throw MCPFailure("not_found_or_denied") }
        guard entry.store.loadError == nil else { throw MCPFailure("library_unavailable") }
        return entry
    }
    func check(_ entry: NoteLibrary.Entry, revision: String, retryFailedSave: Bool = false) throws {
        guard !(isBusy?(entry.id) ?? false), !entry.store.isDirty || (retryFailedSave && entry.store.saveError != nil) else { throw MCPFailure("busy_editing") }
        guard try MCPJSON.revision(entry.store.document) == revision else { throw MCPFailure("revision_conflict") }
    }
    func invoke(_ name: String, args: [String: Any], grant: MCPGrant) async -> [String: Any] {
        do { return try await call(name,args:args,grant:grant) }
        catch { return ["status":"failed","error": (error as? MCPFailure)?.code ?? "save_failed"] }
    }
    private func call(_ name: String, args: [String: Any], grant: MCPGrant) async throws -> [String: Any] {
        guard let op = MCPRegistry.operations.first(where: { $0.name == name }) else { throw MCPFailure("unsupported") }
        try op.validate(args)
        guard validateGrant?(grant) != false else { throw MCPFailure("permission_denied") }
        if let permission = op.permission, !grant.permissions.contains(permission) { throw MCPFailure("permission_denied") }
        if name == "foldpin_get_capabilities" { return ["status":"completed","libraryId":grant.libraryID,"protocolVersion":MCPRegistry.version,"operations":MCPRegistry.operations.filter { $0.permission == nil || grant.permissions.contains($0.permission!) }.map(\.name),"limits":["requestBytes":2_097_152,"pageSize":100,"assetChunkBytes":262144],"authorization":"local bearer credentials; OAuth is not implemented"] }
        if name == "foldpin_get_status" { return ["status":"completed","libraryId":grant.libraryID,"available":grant.libraryID == libraryID && library().canCreate,"busy":executing] }
        guard try args.string("libraryId") == grant.libraryID else { throw MCPFailure("library_unavailable") }
        guard library().canCreate else { throw MCPFailure("library_unavailable") }
        if op.writes && !["foldpin_stop_recording","foldpin_pause_recording","foldpin_resume_recording"].contains(name) && AudioBlockModel.recording != nil { throw MCPFailure("busy_editing") }
        if ["foldpin_get_operation","foldpin_cancel_operation"].contains(name) {
            let id = try args.uuid("operationId")
            guard let state = states[id], state.0 == grant.id else { throw MCPFailure("not_found_or_denied") }
            if name == "foldpin_cancel_operation" {
                cancelled.insert(id); pending.removeValue(forKey:id); if activeOperation == id { cancelNative?() }
                if state.1["status"] as? String == "awaiting_user" { states[id] = (grant.id,["operationId":id.uuidString,"status":"cancelled"]) }
            }
            return states[id]!.1
        }
        guard grant.libraryID == libraryID else { throw MCPFailure("library_unavailable") }
        if !op.writes {
            if ["foldpin_get_shortcuts","foldpin_list_code_themes","foldpin_get_library_location","foldpin_get_login_status"].contains(name) {
                guard let native else { throw MCPFailure("unsupported") }; return try await native(name,args,grant)
            }
            return try read(name,args,grant)
        }
        let key = journal.key(client:grant.id,key:try args.string("idempotencyKey"))
        let fingerprint = try MCPJSON.hash(["name":name,"arguments":args])
        if let receipt = try journal.read(key) {
            guard receipt.fingerprint == fingerprint, receipt.libraryID == libraryID else { throw MCPFailure("invalid_input") }
            if let pending = states[receipt.operationID] { return pending.1 }
            if let result = receipt.result { return try JSONSerialization.jsonObject(with:result) as! [String:Any] }
            // Recover an already-saved create/content change without repeating it.
            if let id = receipt.createdNoteID ?? receipt.editedNoteID,
               let saved = (library().entries + library().deletedEntries).first(where: { $0.id == id }),
               allowed(id,grant), saved.store.loadError == nil,
               receipt.expectedContentHash == (try? MCPJSON.hash(MCPJSON.object(saved.store.document.content))) {
                var recovered = try summary(saved); recovered["operationId"] = receipt.operationID.uuidString
                recovered["status"] = "completed"; recovered["recovered"] = true
                var finished = receipt; finished.result = try MCPJSON.data(recovered); finished.status = "completed"
                try journal.write(finished,key:key); return recovered
            }
            // Ambiguous effects are never blindly replayed.
            return ["operationId":receipt.operationID.uuidString,"status":"interrupted","error":"review_required_before_retry"]
        }
        guard !executing, !(isBusy?(nil) ?? false) else { throw MCPFailure("busy_editing") }
        let id = UUID()
        var receipt = MCPJournal.Receipt(operationID:id,fingerprint:fingerprint,client:grant.id,libraryID:libraryID,tool:name,status:op.confirmation ? "awaiting_user" : "executing")
        if name == "foldpin_create_note" || name == "foldpin_duplicate_note" { receipt.createdNoteID = UUID() }
        try journal.write(receipt,key:key)
        if op.confirmation {
            // Fixed args/revisions are captured here. No confirmed=true parameter exists.
            try preflight(args,grant)
            pending[id] = (name,args,grant,key)
            let result: [String:Any] = ["operationId":id.uuidString,"status":"awaiting_user"]
            states[id] = (grant.id,result)
            requestConfirmation?(id,name,args,grant)
            return result
        }
        if ["foldpin_paste_clipboard","foldpin_scan_storage"].contains(name) {
            try preflight(args,grant)
            let result:[String:Any] = ["operationId":id.uuidString,"status":"executing"]
            states[id] = (grant.id,result)
            executing = true; activeOperation = id
            Task { _ = await self.execute(name,args,grant,key,receipt) }
            return result
        }
        return await execute(name,args,grant,key,receipt)
    }
    func approve(_ id: UUID) async {
        guard let (name,args,grant,key) = pending.removeValue(forKey:id), let receipt = try? journal.read(key) else { return }
        guard !cancelled.contains(id), validateGrant?(grant) != false, Date().timeIntervalSince(receipt.createdAt) < 300 else {
            states[id] = (grant.id,["operationId":id.uuidString,"status":"cancelled"]); return
        }
        if executing { states[id] = (grant.id,["operationId":id.uuidString,"status":"failed","error":"busy_editing"]); return }
        _ = await execute(name,args,grant,key,receipt)
    }
    func reject(_ id: UUID) { cancelled.insert(id); if activeOperation == id { cancelNative?() }; if let value = pending.removeValue(forKey:id) { states[id] = (value.2.id,["operationId":id.uuidString,"status":"cancelled"]) } }
    func cancelAll() { for id in Array(pending.keys) { reject(id) }; if let id = activeOperation { cancelled.insert(id); cancelNative?() } }
    private func preflight(_ args: [String:Any], _ grant: MCPGrant, retryFailedSave: Bool = false) throws {
        guard grant.libraryID == libraryID, validateGrant?(grant) != false else { throw MCPFailure("permission_denied") }
        if let id = args["noteId"] as? String, let uuid = UUID(uuidString:id) { try check(entry(uuid,grant),revision:try args.string("expectedRevision"),retryFailedSave:retryFailedSave) }
        if let targets = args["targets"] as? [[String:Any]] { for target in targets { try check(entry(target.uuid("noteId"),grant),revision:try target.string("expectedRevision")) } }
    }
    private func execute(_ name: String,_ args: [String:Any],_ grant: MCPGrant,_ key: String,_ original: MCPJournal.Receipt) async -> [String:Any] {
        var receipt = original
        executing = true; activeOperation = original.operationID; activeReceiptKey = key; defer { executing = false; activeOperation = nil; activeReceiptKey = nil; cancelNative = nil }
        states[original.operationID] = (grant.id,["operationId":original.operationID.uuidString,"status":"executing"])
        var result: [String:Any]
        do {
            guard !cancelled.contains(receipt.operationID), !(isBusy?(nil) ?? false) else { throw MCPFailure("cancelled") }
            try preflight(args,grant,retryFailedSave:name == "foldpin_retry_storage")
            result = try await write(name,args,grant,createdID:receipt.createdNoteID)
            if result["status"] == nil { result["status"] = "completed" }
        } catch { result = ["status":"failed","error":(error as? MCPFailure)?.code ?? "save_failed"] }
        result["operationId"] = receipt.operationID.uuidString
        receipt.status = result["status"] as? String ?? "failed"
        receipt.result = try? MCPJSON.data(result)
        do { try journal.write(receipt,key:key) }
        catch { result = ["operationId":receipt.operationID.uuidString,"status":"interrupted","error":"receipt_save_failed"] }
        states[receipt.operationID] = (grant.id,result)
        if states.count > 1000 { let keep = Set(pending.keys); for id in Array(states.keys).prefix(100) where !keep.contains(id) { states.removeValue(forKey:id) } }
        didChange?()
        return result
    }
    private func summary(_ entry: NoteLibrary.Entry) throws -> [String:Any] {
        let d = entry.store.document
        return ["noteId":entry.id.uuidString,"title":String(d.summary().prefix(200)),"revision":try MCPJSON.revision(d),"favorite":d.isFavorite,"color":d.color.rawValue,"shelved":d.isShelved,"deleted":d.deletedAt != nil]
    }
    private func read(_ name: String,_ args: [String:Any],_ grant: MCPGrant) throws -> [String:Any] {
        switch name {
        case "foldpin_list_notes","foldpin_search_notes":
            let state = args["state"] as? String ?? "active"
            if state == "deleted", !grant.permissions.contains(.trash) && !grant.permissions.contains(.purge) { throw MCPFailure("permission_denied") }
            var entries = (state == "deleted" ? library().deletedEntries : library().entries).filter { allowed($0.id,grant) && $0.store.loadError == nil }
            if state == "desktop" { entries = entries.filter { !$0.store.document.isShelved } }
            if state == "shelved" { entries = entries.filter { $0.store.document.isShelved } }
            if let q = args["query"] as? String, !q.isEmpty { entries = entries.filter { $0.store.document.text.localizedCaseInsensitiveContains(q) } }
            if let f = args["favorite"] as? Bool { entries = entries.filter { $0.store.document.isFavorite == f } }
            if let kind = args["kind"] as? String { entries = entries.filter { $0.store.document.content.blocks.contains { $0.kind.rawValue == kind } } }
            if let id = args["collectionId"] as? String { let members = collections().collections.first { $0.id.uuidString == id }?.members ?? []; entries = entries.filter { members.contains($0.id) } }
            entries.sort { $0.store.document.modifiedAt > $1.store.document.modifiedAt }
            let offset=args.int("cursor"), limit=args.int("limit",default:30)
            let values=try entries.dropFirst(offset).prefix(limit).map(summary)
            return ["status":"completed","notes":values,"nextCursor":offset+values.count < entries.count ? offset+values.count as Any : NSNull()]
        case "foldpin_read_note","foldpin_read_blocks":
            let e = try entry(args.uuid("noteId"),grant); var result = try summary(e)
            let offset=args.int("cursor"), limit=args.int("limit",default:30)
            let page=Array(e.store.document.content.blocks.dropFirst(offset).prefix(limit))
            let encoded = try MCPJSON.object(page)
            guard try MCPJSON.data(encoded).count <= 1_500_000 else { throw MCPFailure("limit_exceeded") }
            result["blocks"]=encoded; result["nextCursor"]=offset+page.count < e.store.document.content.blocks.count ? offset+page.count as Any : NSNull(); result["status"]="completed"
            return result
        case "foldpin_list_collections":
            let c=collections(); guard !c.unreadable else { throw MCPFailure("library_unavailable") }
            let all=try MCPJSON.object(c.collections)
            let values=c.collections.compactMap { c -> [String:Any]? in
                let ids=c.members.filter { allowed($0,grant) }; guard grant.noteIDs == nil || grant.collectionIDs.contains(c.id) || !ids.isEmpty else { return nil }
                return ["collectionId":c.id.uuidString,"name":c.name,"noteIds":ids.map(\.uuidString)]
            }
            return ["status":"completed","collections":values,"revision":try MCPJSON.hash(all)]
        case "foldpin_find_in_note":
            let e=try entry(args.uuid("noteId"),grant), query=try args.string("query")
            guard !query.isEmpty else { throw MCPFailure("invalid_input") }
            var matches:[[String:Any]]=[]
            for block in e.store.document.content.blocks {
                let text=block.text as NSString; var location=0
                while location < text.length {
                    let range=text.range(of:query,range:NSRange(location:location,length:text.length-location))
                    if range.location == NSNotFound { break }
                    guard matches.count < 1000 else { throw MCPFailure("limit_exceeded") }
                    matches.append(["blockId":block.id.uuidString,"location":range.location,"length":range.length]); location=NSMaxRange(range)
                }
            }
            return ["status":"completed","matches":matches,"revision":try MCPJSON.revision(e.store.document)]
        case "foldpin_list_assets":
            let e=try entry(args.uuid("noteId"),grant)
            return ["status":"completed","assets":e.store.document.content.blocks.compactMap { b -> [String:Any]? in
                guard let id=b.image?.id ?? b.audio?.id ?? b.video?.id ?? b.attachment?.id else { return nil }
                return ["blockId":b.id.uuidString,"assetId":id.uuidString,"kind":b.kind.rawValue]
            }]
        case "foldpin_read_asset":
            let e=try entry(args.uuid("noteId"),grant), url=try assetURL(e,blockID:args.uuid("blockId"))
            let handle=try FileHandle(forReadingFrom:url); defer { try? handle.close() }
            let size=try handle.seekToEnd(); let offset=UInt64(args.int("offset")); guard offset<=size else { throw MCPFailure("invalid_input") }
            try handle.seek(toOffset:offset); let data=try handle.read(upToCount:args.int("length",default:262144)) ?? Data()
            return ["status":"completed","base64":data.base64EncodedString(),"offset":offset,"totalBytes":size,"eof":offset+UInt64(data.count)>=size]
        case "foldpin_list_changes": return ["status":"completed","changes":changes.values.filter { $0.client == grant.id && $0.library == libraryID && allowed($0.note,grant) }.map { ["changeId":$0.id.uuidString,"noteId":$0.note.uuidString,"revision":$0.revision,"undone":$0.undone] as [String:Any] }]
        case "foldpin_get_settings": return try settings()
        default: throw MCPFailure("unsupported")
        }
    }
    func assetURL(_ e: NoteLibrary.Entry, blockID: UUID) throws -> URL {
        guard let b=e.store.document.content.blocks.first(where: { $0.id==blockID }) else { throw MCPFailure("not_found_or_denied") }
        let file=e.store.file; guard let assets=file.assetDirectory else { throw MCPFailure("asset_unavailable") }; let url:URL
        if let i=b.image, !i.isRemotePlaceholder { url=assets.appendingPathComponent(i.id.uuidString+".original") }
        else if let a=b.audio, !a.isDraft { url=file.audioURL(a) }
        else if let v=b.video { url=file.videoURL(v) }
        else if let a=b.attachment { url=a.url(in:assets.appendingPathComponent("files")) }
        else { throw MCPFailure("asset_unavailable") }
        let root=assets.standardizedFileURL
        guard url.standardizedFileURL.path.hasPrefix(root.path+"/"), url.resolvingSymlinksInPath().path==url.standardizedFileURL.path else { throw MCPFailure("asset_unavailable") }
        let info=try url.resourceValues(forKeys:[.isRegularFileKey,.isSymbolicLinkKey]); guard info.isRegularFile==true,info.isSymbolicLink != true else { throw MCPFailure("asset_unavailable") }
        return url
    }
    func settings() throws -> [String:Any] {
        let fields:[String:Any]=["theme":UserDefaults.standard.string(forKey:"appTheme") ?? "system","appearance":UserDefaults.standard.string(forKey:"noteAppearance") ?? "paper","language":UserDefaults.standard.stringArray(forKey:"AppleLanguages")?.first ?? "system"]
        return ["status":"completed","settings":fields,"revision":try MCPJSON.hash(fields)]
    }
    func content(_ args: [String:Any]) throws -> NoteContent {
        guard (args["text"] == nil) != (args["blocks"] == nil) else { throw MCPFailure("invalid_input") }
        if let values=args["blocks"] as? [[String:Any]] { return NoteContent(blocks:try values.map(block)) }
        let text=try args.string("text")
        if args["format"] as? String == "markdown" { return MarkdownPasteParser.parse(text, importingRemoteImages: false) ?? NoteContent(plainText:text) }
        return NoteContent(plainText:text)
    }
    func block(_ args: [String:Any]) throws -> NoteBlock {
        guard let kind=NoteBlockKind(rawValue:try args.string("kind")) else { throw MCPFailure("invalid_input") }
        var b=NoteBlock(kind:kind,text:args["text"] as? String ?? "")
        if let id=args["id"] as? String { guard let uuid=UUID(uuidString:id) else { throw MCPFailure("invalid_input") }; b.id=uuid }
        b.isChecked=args.bool("isChecked")
        if let l=args["language"] as? String { b.language=CodeLanguage(rawValue:l) ?? .plain }
        if let table=args["table"] { b.table=try MCPJSON.decode(NoteTable.self,table) }
        return b
    }
    func saveContent(_ next:NoteContent,_ e:NoteLibrary.Entry,_ grant:MCPGrant, record:Bool=true) throws -> [String:Any] {
        try next.validate()
        guard next.blocks.count<=10000, try JSONEncoder().encode(next).count<=2_097_152 else { throw MCPFailure("limit_exceeded") }
        try recordIntendedContent(next, note:e.id)
        let before=e.store.document.content
        if let commitContent { try commitContent(e,next) } else { e.store.edit(next); guard e.store.flush() else { throw MCPFailure("save_failed") } }
        var result=try summary(e)
        if record, before != next {
            let id=UUID(); changes[id]=Change(id:id,client:grant.id,note:e.id,library:libraryID,before:before,after:next,revision:try MCPJSON.revision(e.store.document)); result["changeId"]=id.uuidString
        }
        return result
    }
    private func recordIntendedContent(_ content:NoteContent,note:UUID) throws {
        guard let key=activeReceiptKey,var receipt=try journal.read(key) else { return }
        receipt.editedNoteID=note;receipt.expectedContentHash=try MCPJSON.hash(MCPJSON.object(content))
        try journal.write(receipt,key:key)
    }
    private func write(_ name:String,_ args:[String:Any],_ grant:MCPGrant,createdID:UUID?) async throws -> [String:Any] {
        let short=String(name.dropFirst("foldpin_".count))
        if short == "create_note" || short == "duplicate_note" {
            // Restricted clients cannot create notes outside their approved set.
            guard grant.noteIDs == nil else { throw MCPFailure("permission_denied") }
            var document=NoteDocument(); document.id=createdID!; document.isShelved=true
            if short == "create_note" {
                document.content=try content(args)
                if let c=args["color"] as? String { document.color=NoteColor(rawValue:c)! }
                if let icon=args["icon"] as? String { guard let icon=NoteIcon.normalized(icon) else { throw MCPFailure("invalid_input") }; document.icon=icon }
            } else {
                guard grant.permissions.contains(.read) else { throw MCPFailure("permission_denied") }
                document=try entry(args.uuid("noteId"),grant,deleted:false).store.document; document.id=createdID!; document.isShelved=true; document.deletedAt=nil; document.conflictOf=nil
                document.content.blocks=document.content.blocks.map { var b=$0;b.id=UUID();return b }; document.createdAt=Date();document.modifiedAt=document.createdAt
            }
            try document.validate(); try recordIntendedContent(document.content,note:document.id); return try summary(library().importDocument(document))
        }
        if ["create_collection","rename_collection","delete_collection","set_collection_membership"].contains(short) {
            guard grant.noteIDs == nil else { throw MCPFailure("permission_denied") }
            let c=collections(); guard !c.unreadable else { throw MCPFailure("library_unavailable") }
            guard try MCPJSON.hash(MCPJSON.object(c.collections)) == args.string("expectedRevision") else { throw MCPFailure("revision_conflict") }
            let ok:Bool; var id:UUID?
            switch short {
            case "create_collection": id=c.create(try args.string("name"));ok=id != nil
            case "rename_collection": ok=c.rename(try args.uuid("collectionId"),to:try args.string("name"))
            case "delete_collection": ok=c.remove(try args.uuid("collectionId"))
            default:
                let ids=try args.strings("noteIds").map { text -> UUID in guard let id=UUID(uuidString:text) else { throw MCPFailure("invalid_input") };_ = try entry(id,grant);return id }
                ok=c.setMembership(Set(ids),collection:try args.uuid("collectionId"),included:args.bool("included"))
            }
            guard ok else { throw MCPFailure("save_failed") }
            return ["collectionId":id?.uuidString as Any? ?? args["collectionId"] ?? NSNull(),"revision":try MCPJSON.hash(MCPJSON.object(c.collections))]
        }
        if ["trash_notes","restore_notes","purge_notes"].contains(short) {
            guard let targets=args["targets"] as? [[String:Any]], !targets.isEmpty else { throw MCPFailure("invalid_input") }
            var results:[[String:Any]]=[]
            for target in targets {
                let id=try target.uuid("noteId")
                do {
                    let e=try entry(id,grant);try check(e,revision:try target.string("expectedRevision"))
                    if short == "trash_notes" { guard library().deleteNote(id) else { throw MCPFailure("save_failed") } }
                    else if short == "restore_notes" { guard library().restoreNote(id,toShelf:true) != nil else { throw MCPFailure("save_failed") } }
                    else { try library().permanentlyDeleteNote(id) }
                    results.append(["noteId":id.uuidString,"status":"completed"])
                } catch { results.append(["noteId":id.uuidString,"status":"failed","error":(error as? MCPFailure)?.code ?? "save_failed"]) }
            }
            return ["results":results]
        }
        let contentOps=["update_note","insert_blocks","update_blocks","move_blocks","duplicate_blocks","delete_blocks","set_todo","edit_inline_format","replace_in_note","edit_table","update_image","update_audio","undo_change","redo_change"]
        if contentOps.contains(short) {
            let e=try entry(args.uuid("noteId"),grant,deleted:false); var next=e.store.document.content
            if short == "undo_change" || short == "redo_change" {
                let id=try args.uuid("changeId")
                guard var c=changes[id], c.client==grant.id,c.note==e.id,c.library==libraryID,c.undone == (short == "redo_change"),c.revision == (try MCPJSON.revision(e.store.document)) else { throw MCPFailure("revision_conflict") }
                let result=try saveContent(short == "undo_change" ? c.before : c.after,e,grant,record:false)
                c.undone.toggle();c.revision=try MCPJSON.revision(e.store.document);changes[id]=c;return result
            }
            if short == "update_note" { next=try content(args) }
            else { try edit(short,args,&next) }
            return try saveContent(next,e,grant)
        }
        if short == "set_note_metadata" {
            let e=try entry(args.uuid("noteId"),grant,deleted:false)
            if let icon=args["icon"] as? String, NoteIcon.normalized(icon)==nil { throw MCPFailure("invalid_input") }
            if let color=args["color"] as? String { e.store.setColor(NoteColor(rawValue:color)!) }
            if args.bool("removeIcon") { _=e.store.setIcon(nil) } else if let icon=args["icon"] as? String { _=e.store.setIcon(icon) }
            if let favorite=args["favorite"] as? Bool { guard e.store.setFavorite(favorite) else { throw MCPFailure("save_failed") } }
            guard e.store.flush() else { throw MCPFailure("save_failed") }; return try summary(e)
        }
        if short == "retry_storage" { let e=try entry(args.uuid("noteId"),grant);guard e.store.flush() else { throw MCPFailure("save_failed") };return try summary(e) }
        guard let native else { throw MCPFailure("unsupported") }
        return try await native(name,args,grant)
    }
    private func edit(_ op:String,_ args:[String:Any],_ content:inout NoteContent) throws {
        func index(_ key:String="blockId") throws -> Int { guard let i=content.blocks.firstIndex(where:{$0.id == (try? args.uuid(key))}) else { throw MCPFailure("not_found_or_denied") };return i }
        if ["insert_blocks","update_blocks"].contains(op) {
            guard let values=args["blocks"] as? [[String:Any]], !values.isEmpty else { throw MCPFailure("invalid_input") }
            let blocks=try values.map(block)
            if op == "insert_blocks" { let i=args["beforeBlockId"] == nil ? content.blocks.count : try index("beforeBlockId");content.blocks.insert(contentsOf:blocks,at:i) }
            else { for b in blocks { guard let i=content.blocks.firstIndex(where:{$0.id==b.id}) else { throw MCPFailure("not_found_or_denied") };content.blocks[i]=b } }
        } else if ["move_blocks","duplicate_blocks","delete_blocks"].contains(op) {
            let ids=Set(try args.strings("blockIds").compactMap(UUID.init(uuidString:)))
            guard !ids.isEmpty, ids.isSubset(of:Set(content.blocks.map(\.id))) else { throw MCPFailure("not_found_or_denied") }
            var blocks=content.blocks.filter{ids.contains($0.id)}
            let anchor=try args["beforeBlockId"].map{_ in try args.uuid("beforeBlockId")}
            if let anchor { guard content.blocks.contains(where:{$0.id==anchor}),!ids.contains(anchor) else { throw MCPFailure("invalid_input") } }
            if op != "duplicate_blocks" { content.blocks.removeAll{ids.contains($0.id)} }
            else { blocks=blocks.map{var b=$0;b.id=UUID();return b} }
            if op != "delete_blocks" { let i=anchor.flatMap{a in content.blocks.firstIndex{$0.id==a}} ?? content.blocks.count;content.blocks.insert(contentsOf:blocks,at:i) }
            if content.blocks.isEmpty { content=NoteContent() }
        } else if op == "replace_in_note" {
            let query=try args.string("query"),replacement=try args.string("replacement")
            guard !query.isEmpty else { throw MCPFailure("invalid_input") }
            let id=try args["blockId"].map{_ in try args.uuid("blockId")}
            if id != nil { _=try index() }
            for i in content.blocks.indices where !content.blocks[i].kind.isAttachment && (id == nil || content.blocks[i].id==id) {
                var b=content.blocks[i]; var text=b.text as NSString; var offset=0
                while offset<text.length {
                    let r=text.range(of:query,range:NSRange(location:offset,length:text.length-offset)); if r.location==NSNotFound{break}
                    try validRange(r,in:b.text)
                    let delta=(replacement as NSString).length-r.length
                    b.marks=b.marks.flatMap{mark -> [NoteTextMark] in
                        let end=mark.location+mark.length
                        if end<=r.location{return [mark]}
                        if mark.location>=NSMaxRange(r){var m=mark;m.location+=delta;return [m]}
                        var out:[NoteTextMark]=[]
                        if mark.location<r.location{var m=mark;m.length=r.location-mark.location;out.append(m)}
                        if end>NSMaxRange(r){var m=mark;m.location=NSMaxRange(r)+delta;m.length=end-NSMaxRange(r);out.append(m)}
                        return out
                    }
                    b.text=text.replacingCharacters(in:r,with:replacement);text=b.text as NSString;offset=r.location+(replacement as NSString).length
                }
                content.blocks[i]=b
            }
        } else {
            let i=try index(); var b=content.blocks[i]
            switch op {
            case "set_todo": guard b.kind == .task else{throw MCPFailure("invalid_input")};b.isChecked=args.bool("completed")
            case "update_image":
                guard var image=b.image else{throw MCPFailure("invalid_input")}
                if args.bool("resetSize"){image.displayWidth=nil}else if let width=args["width"] as? NSNumber{image.displayWidth=width.doubleValue}
                if let caption=args["caption"] as? String{image.caption=caption};b.image=image
            case "update_audio":guard var audio=b.audio,!audio.isDraft else{throw MCPFailure("busy_editing")};audio.name=try args.string("name");b.audio=audio
            case "edit_inline_format":
                guard !b.kind.isAttachment else{throw MCPFailure("invalid_input")}
                let r=NSRange(location:args.int("location"),length:args.int("length"));try validRange(r,in:b.text)
                let format=try args.string("format"),enabled=args.bool("enabled",default:true)
                var boundaries=Set([r.location,NSMaxRange(r)])
                for m in b.marks {boundaries.insert(m.location);boundaries.insert(m.location+m.length)}
                let points=boundaries.sorted();var marks:[NoteTextMark]=[]
                for (start,end) in zip(points,points.dropFirst()) where end>start {
                    let active=b.marks.filter{$0.location<=start && $0.location+$0.length>=end}
                    var m=NoteTextMark(location:start,length:end-start,bold:active.contains{$0.bold},italic:active.contains{$0.italic},code:active.contains{$0.code},strikethrough:active.contains{$0.strikethrough},link:active.compactMap(\.link).last)
                    if start>=r.location && end<=NSMaxRange(r){switch format {
                    case "bold":m.bold=enabled
                    case "italic":m.italic=enabled
                    case "code":m.code=enabled
                    case "strikethrough":m.strikethrough=enabled
                    case "link":m.link=enabled ? try args.string("url") : nil;if enabled && m.clickableURL==nil{throw MCPFailure("invalid_input")}
                    default:m=NoteTextMark(location:start,length:end-start)
                    }}
                    if m.hasStyle{marks.append(m)}
                };b.marks=marks
            case "edit_table":
                guard var table=b.table else{throw MCPFailure("invalid_input")}
                let row=args.int("row"),column=args.int("column")
                switch try args.string("action") {
                case "cell":guard table.rows.indices.contains(row),column<table.columnCount else{throw MCPFailure("invalid_input")};table.rows[row][column]=try args.string("text")
                case "insert_row":guard row<=table.rows.count,table.rows.count<100 else{throw MCPFailure("limit_exceeded")};table.rows.insert(Array(repeating:"",count:table.columnCount),at:row)
                case "delete_row":guard table.rows.count>1,table.rows.indices.contains(row) else{throw MCPFailure("invalid_input")};table.rows.remove(at:row)
                case "insert_column":guard column<=table.columnCount,table.columnCount<30 else{throw MCPFailure("limit_exceeded")};for r in table.rows.indices{table.rows[r].insert("",at:column)}
                case "delete_column":guard table.columnCount>1,column<table.columnCount else{throw MCPFailure("invalid_input")};for r in table.rows.indices{table.rows[r].remove(at:column)}
                default:if let v=args["headerRow"] as? Bool{table.headerRow=v};if let v=args["headerColumn"] as? Bool{table.headerColumn=v}
                };b.table=table
            default:throw MCPFailure("unsupported")
            }
            content.blocks[i]=b
        }
    }
    private func validRange(_ r:NSRange,in text:String) throws {
        let length=(text as NSString).length
        guard r.location>=0,r.length>0,r.location<=length,r.length<=length-r.location else{throw MCPFailure("invalid_input")}
        let ns=text as NSString
        guard ns.rangeOfComposedCharacterSequences(for:r)==r else{throw MCPFailure("invalid_input")}
    }
}
