import Foundation
import AppKit
import Testing
@testable import FoldpinCore

@MainActor private final class MemoryCredentials:MCPCredentialStore {
    var values:[UUID:String]=[:]
    func set(_ token:String,client:UUID)throws{values[client]=token}
    func get(client:UUID)throws->String?{values[client]}
    func remove(client:UUID)throws{values.removeValue(forKey:client)}
}
@Suite @MainActor struct MCPTests {
    private func fixture() -> (URL,NoteLibrary,FoldpinCommandService,MCPGrant) {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("Foldpin.MCP.Tests."+UUID().uuidString)
        let library=NoteLibrary(directory:root.appendingPathComponent("library"),localDirectory:root.appendingPathComponent("local"),createsInitialNote:false)
        let service=FoldpinCommandService(library:{library},journal:MCPJournal(directory:root.appendingPathComponent("receipts")))
        return(root,library,service,MCPGrant(name:"Test",libraryID:service.libraryID,permissions:Set(MCPPermission.allCases),noteIDs:nil))
    }
    private func create(_ service:FoldpinCommandService,_ grant:MCPGrant,text:String="Test",key:String="create")async -> [String:Any]{await service.invoke("foldpin_create_note",args:["libraryId":service.libraryID,"idempotencyKey":key,"text":text],grant:grant)}
    @Test func clipboardSnapshotPreservesBlocksAndRejectsUnscopedAssets() async throws {
        let board=NSPasteboard.withUniqueName();defer{board.releaseGlobally()}
        let original=NoteContent(blocks:[NoteBlock(kind:.task,text:"Task",isChecked:true)])
        board.setData(try JSONEncoder().encode(original),forType:.init("dev.jasonyu.foldpin.blocks.v1"))
        let snapshot=try MCPClipboard.capture(board,allowAssets:false,resourceIsAllowed:{_ in false})
        let content=try await snapshot.prepare(assets:FileManager.default.temporaryDirectory)
        #expect(content.blocks.first?.isChecked==true);#expect(content.blocks.first?.id != original.blocks.first?.id)
        let image=NoteImage(id:UUID(),name:"Denied",pixelWidth:10,pixelHeight:10)
        board.clearContents();board.setData(try JSONEncoder().encode(NoteContent(blocks:[NoteBlock(kind:.image,image:image)])),forType:.init("dev.jasonyu.foldpin.blocks.v1"))
        #expect(throws:MCPFailure.self){try MCPClipboard.capture(board,allowAssets:true,resourceIsAllowed:{_ in false})}
    }
    @Test func clipboardFileImportUsesCopiedBytesAndExplicitAssetPermission() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer{try? FileManager.default.removeItem(at:root)}
        let url=root.appendingPathComponent("sample.txt");try Data("Original attachment".utf8).write(to:url)
        let board=NSPasteboard.withUniqueName();defer{board.releaseGlobally()}
        board.writeObjects([url as NSURL])
        #expect(throws:MCPFailure.self){try MCPClipboard.capture(board,allowAssets:false,resourceIsAllowed:{_ in false})}
        let snapshot=try MCPClipboard.capture(board,allowAssets:true,resourceIsAllowed:{_ in false})
        let assets=root.appendingPathComponent("assets")
        let content=try await snapshot.prepare(assets:assets)
        let attachment=try #require(content.blocks.first?.attachment)
        #expect(attachment.name=="sample.txt")
        #expect(try Data(contentsOf:attachment.url(in:assets.appendingPathComponent("files")))==Data(contentsOf:url))
    }
    @Test func longOperationReturnsIdentityAndReplayDoesNotRunTwice() async throws {
        let(root,_,service,grant)=fixture();defer{try? FileManager.default.removeItem(at:root)}
        var invocations=0
        service.native={_,_,_ in invocations+=1;try await Task.sleep(for:.milliseconds(30));return ["status":"completed","totalBytes":123]}
        let args:[String:Any]=["libraryId":service.libraryID,"idempotencyKey":"scan"]
        let started=await service.invoke("foldpin_scan_storage",args:args,grant:grant)
        #expect(started["status"] as? String=="executing")
        let replay=await service.invoke("foldpin_scan_storage",args:args,grant:grant)
        #expect(replay["operationId"] as? String==started["operationId"] as? String)
        var status=started
        for _ in 0..<100 {
            status=await service.invoke("foldpin_get_operation",args:["libraryId":service.libraryID,"operationId":started["operationId"]!],grant:grant)
            if status["status"] as? String=="completed"{break}
            try await Task.sleep(for:.milliseconds(10))
        }
        #expect(status["totalBytes"] as? Int==123);#expect(invocations==1)
    }
    @Test func createIsCollectedAndReplaySurvivesServiceRestart() async throws {
        let(root,library,service,grant)=fixture();defer{try? FileManager.default.removeItem(at:root)}
        let first=await create(service,grant);#expect(first["status"] as? String=="completed")
        #expect(library.entries.count==1);#expect(library.entries[0].store.document.isShelved)
        let again=FoldpinCommandService(library:{library},journal:service.journal)
        let replay=await create(again,grant);#expect(first["noteId"] as? String==replay["noteId"] as? String);#expect(library.entries.count==1)
        let mismatch=await create(again,grant,text:"Different");#expect(mismatch["error"] as? String=="invalid_input")
    }
    @Test func failedSaveRetryKeepsRevisionAndEditingProtection() async throws {
        let(root,library,service,grant)=fixture();defer{try? FileManager.default.removeItem(at:root)}
        _=await create(service,grant)
        let e=library.entries[0],url=e.store.file.url,backup=root.appendingPathComponent("saved-note.json")
        try FileManager.default.moveItem(at:url,to:backup)
        try FileManager.default.createDirectory(at:url,withIntermediateDirectories:false)
        try Data("block replacement".utf8).write(to:url.appendingPathComponent("keep"))
        e.store.edit("Unsaved human content");#expect(!e.store.flush());#expect(e.store.saveError != nil)
        var args:[String:Any]=["libraryId":service.libraryID,"noteId":e.id.uuidString,"expectedRevision":try MCPJSON.revision(e.store.document),"idempotencyKey":"retry-busy"]
        service.isBusy={_ in true}
        let busy=await service.invoke("foldpin_retry_storage",args:args,grant:grant)
        #expect(busy["error"] as? String=="busy_editing")
        service.isBusy=nil
        try FileManager.default.removeItem(at:url);try FileManager.default.moveItem(at:backup,to:url)
        args["idempotencyKey"]="retry-ok"
        let result=await service.invoke("foldpin_retry_storage",args:args,grant:grant)
        #expect(result["status"] as? String=="completed");#expect(!e.store.isDirty)
        #expect(try e.store.file.load().text=="Unsaved human content")
    }
    @Test func staleRevisionAndBusyEditorNeverOverwrite() async throws {
        let(root,library,service,grant)=fixture();defer{try? FileManager.default.removeItem(at:root)}
        let first=await create(service,grant)
        let args:[String:Any]=["libraryId":service.libraryID,"idempotencyKey":"update","noteId":first["noteId"]!,"expectedRevision":first["revision"]!,"text":"AI edit"]
        library.entries[0].store.edit("Human edit");#expect(library.entries[0].store.flush())
        let rejected=await service.invoke("foldpin_update_note",args:args,grant:grant)
        #expect(rejected["error"] as? String=="revision_conflict");#expect(library.entries[0].store.document.text=="Human edit")
        var fresh=args;fresh["idempotencyKey"]="busy";fresh["expectedRevision"]=try MCPJSON.revision(library.entries[0].store.document)
        service.isBusy={_ in true};let busy=await service.invoke("foldpin_update_note",args:fresh,grant:grant)
        #expect(busy["error"] as? String=="busy_editing");#expect(library.entries[0].store.document.text=="Human edit")
    }
    @Test func scopedSearchAndUnknownNoteHaveSameDenial() async throws {
        let(root,library,service,grant)=fixture();defer{try? FileManager.default.removeItem(at:root)}
        _=await create(service,grant,text:"Secret")
        var restricted=grant;restricted.noteIDs=[]
        let list=await service.invoke("foldpin_search_notes",args:["libraryId":service.libraryID,"query":"Secret"],grant:restricted)
        #expect((list["notes"] as? [Any])?.isEmpty==true)
        for id in [library.entries[0].id,UUID()]{let r=await service.invoke("foldpin_read_note",args:["libraryId":service.libraryID,"noteId":id.uuidString],grant:restricted);#expect(r["error"] as? String=="not_found_or_denied")}
        restricted.permissions=[];let denied=await create(service,restricted,key:"denied");#expect(denied["error"] as? String=="permission_denied")
    }
    @Test func blocksTableAndUndoRespectHumanEdits() async throws {
        let(root,library,service,grant)=fixture();defer{try? FileManager.default.removeItem(at:root)}
        let first=await create(service,grant,text:"Start")
        var args:[String:Any]=["libraryId":service.libraryID,"noteId":first["noteId"]!,"expectedRevision":first["revision"]!,"idempotencyKey":"insert","blocks":[["kind":"task","text":"Task"],["kind":"table"]]]
        let inserted=await service.invoke("foldpin_insert_blocks",args:args,grant:grant);#expect(inserted["status"] as? String=="completed")
        let e=library.entries[0],table=try #require(e.store.document.content.blocks.last)
        args=["libraryId":service.libraryID,"noteId":e.id.uuidString,"expectedRevision":try MCPJSON.revision(e.store.document),"idempotencyKey":"cell","blockId":table.id.uuidString,"action":"cell","row":0,"column":0,"text":"Cell"]
        let edited=await service.invoke("foldpin_edit_table",args:args,grant:grant);#expect(edited["status"] as? String=="completed");#expect(e.store.document.content.blocks.last?.table?.rows[0][0]=="Cell")
        args=["libraryId":service.libraryID,"noteId":e.id.uuidString,"expectedRevision":edited["revision"]!,"idempotencyKey":"undo","changeId":edited["changeId"]!]
        let undo=await service.invoke("foldpin_undo_change",args:args,grant:grant);#expect(undo["status"] as? String=="completed");#expect(e.store.document.content.blocks.last?.table?.rows[0][0]=="")
        e.store.edit("Human after undo");#expect(e.store.flush());args["expectedRevision"]=try MCPJSON.revision(e.store.document);args["idempotencyKey"]="redo"
        let redo=await service.invoke("foldpin_redo_change",args:args,grant:grant);#expect(redo["error"] as? String=="revision_conflict")
    }
    @Test func purgeNeedsLocalApprovalAndRechecksRevision() async throws {
        let(root,library,service,grant)=fixture();defer{try? FileManager.default.removeItem(at:root)}
        let first=await create(service,grant);let id=try #require(UUID(uuidString:first["noteId"] as! String));#expect(library.deleteNote(id))
        let e=library.deletedEntries[0]
        var args:[String:Any]=["libraryId":service.libraryID,"idempotencyKey":"purge","targets":[["noteId":id.uuidString,"expectedRevision":try MCPJSON.revision(e.store.document)]]]
        let pending=await service.invoke("foldpin_purge_notes",args:args,grant:grant);#expect(pending["status"] as? String=="awaiting_user");#expect(library.deletedEntries.count==1)
        #expect(library.restoreNote(id,toShelf:true) != nil)
        let op=try #require(UUID(uuidString:pending["operationId"] as! String));await service.approve(op);#expect(library.entries.count==1)
        args["confirmed"]=true;args["idempotencyKey"]="spoof";let spoof=await service.invoke("foldpin_purge_notes",args:args,grant:grant);#expect(spoof["error"] as? String=="invalid_input")
    }
    @Test func revokedOrCancelledConfirmationCannotExecute() async throws {
        let(root,_,service,grant)=fixture();defer{try? FileManager.default.removeItem(at:root)}
        var ran=false;service.native={_,_,_ in ran=true;return [:]}
        var active=true;service.validateGrant={_ in active}
        let first=await service.invoke("foldpin_quit",args:["libraryId":service.libraryID,"idempotencyKey":"quit"],grant:grant)
        active=false;await service.approve(UUID(uuidString:first["operationId"] as! String)!);#expect(!ran)
        active=true
        let second=await service.invoke("foldpin_quit",args:["libraryId":service.libraryID,"idempotencyKey":"quit2"],grant:grant)
        let id=UUID(uuidString:second["operationId"] as! String)!;service.reject(id);await service.approve(id);#expect(!ran)
    }
    @Test func strictSchemasRejectUnknownFieldsAndInvalidUTF16() async throws {
        let(root,library,service,grant)=fixture();defer{try? FileManager.default.removeItem(at:root)}
        let first=await create(service,grant,text:"👨‍👩‍👧‍👦 test")
        let args:[String:Any]=["libraryId":service.libraryID,"noteId":first["noteId"]!,"expectedRevision":first["revision"]!,"idempotencyKey":"mark","blockId":library.entries[0].store.document.content.blocks[0].id.uuidString,"location":1,"length":1,"format":"bold"]
        let r=await service.invoke("foldpin_edit_inline_format",args:args,grant:grant);#expect(r["error"] as? String=="invalid_input")
        for op in MCPRegistry.operations{#expect(throws:(any Error).self){try op.validate(["unexpected":true])}}
    }
    @Test func transportRejectsRebindingSmugglingAndOversize() throws {
        func request(_ headers:String,body:String="{}")->Data{Data("POST /mcp HTTP/1.1\r\n\(headers)\r\n\r\n\(body)".utf8)}
        let good="Host: 127.0.0.1:51821\r\nContent-Length: 2"
        #expect(try MCPHTTPRequest.parse(request(good),port:51821) != nil)
        for headers in [good+"\r\nOrigin: https://evil.test",good+"\r\nHost: evil.test",good+"\r\nTransfer-Encoding: chunked","Host: evil.test\r\nContent-Length: 2","Host: 127.0.0.1:51821\r\nContent-Length: 2097153"]{
            #expect(throws:(any Error).self){try MCPHTTPRequest.parse(request(headers),port:51821)}
        }
        #expect(throws:(any Error).self){try MCPHTTPRequest.parse(request(good,body:"{}extra"),port:51821)}
    }
    @Test func authenticatedProtocolLifecyclePaginationAndRevocation() async throws {
        let(root,_,service,_)=fixture();defer{try? FileManager.default.removeItem(at:root)}
        let suite="Foldpin.MCP."+UUID().uuidString;let defaults=try #require(UserDefaults(suiteName:suite));defer{defaults.removePersistentDomain(forName:suite)}
        defaults.set(true,forKey:"mcp.enabled")
        let server=MCPServer(commands:service,defaults:defaults,credentials:MemoryCredentials())
        let token=try server.addClient(name:"Test client",permissions:Set(MCPPermission.allCases),noteIDs:nil)
        func request(_ body:[String:Any],session:String?=nil,auth:String?=nil)->MCPHTTPRequest{
            var headers=["authorization":"Bearer "+(auth ?? token),"content-type":"application/json","accept":"application/json, text/event-stream"]
            if let session{headers["mcp-session-id"]=session;headers["mcp-protocol-version"]=MCPRegistry.version}
            return MCPHTTPRequest(method:"POST",headers:headers,body:try! MCPJSON.data(body))
        }
        let initBody:[String:Any]=["jsonrpc":"2.0","id":1,"method":"initialize","params":["protocolVersion":MCPRegistry.version,"clientInfo":["name":"Fake trusted identity","version":"1"]]]
        #expect(await server.handle(request(initBody,auth:"bad")).status==401)
        let response=await server.handle(request(initBody));#expect(response.status==200)
        let session=try #require(response.headers["MCP-Session-Id"])
        #expect(await server.handle(request(["jsonrpc":"2.0","method":"notifications/initialized"],session:session)).status==202)
        let list=await server.handle(request(["jsonrpc":"2.0","id":2,"method":"tools/list"],session:session))
        let result=try #require((JSONSerialization.jsonObject(with:list.body) as? [String:Any])?["result"] as? [String:Any]);#expect((result["tools"] as? [Any])?.count==30);#expect(result["nextCursor"] != nil)
        let other=try server.addClient(name:"Other",permissions:[.read],noteIDs:nil)
        #expect(await server.handle(request(["jsonrpc":"2.0","id":3,"method":"ping"],session:session,auth:other)).status==404)
        server.revoke(server.grants[0].id)
        #expect(await server.handle(request(initBody)).status==401)
    }
    @Test func interruptedSavedContentRecoversWithoutRepeating() async throws {
        let(root,library,service,grant)=fixture();defer{try? FileManager.default.removeItem(at:root)}
        let first=await create(service,grant)
        let key=service.journal.key(client:grant.id,key:"crash")
        let args:[String:Any]=["libraryId":service.libraryID,"idempotencyKey":"crash","noteId":first["noteId"]!,"expectedRevision":first["revision"]!,"text":"Saved before response"]
        let entry=library.entries[0],content=NoteContent(plainText:"Saved before response")
        var receipt=MCPJournal.Receipt(operationID:UUID(),fingerprint:try MCPJSON.hash(["name":"foldpin_update_note","arguments":args]),client:grant.id,libraryID:service.libraryID,tool:"foldpin_update_note",status:"executing")
        receipt.editedNoteID=entry.id;receipt.expectedContentHash=try MCPJSON.hash(MCPJSON.object(content));try service.journal.write(receipt,key:key)
        entry.store.edit(content);#expect(entry.store.flush())
        let before=try Data(contentsOf:entry.store.file.url)
        let replay=await service.invoke("foldpin_update_note",args:args,grant:grant)
        #expect(replay["recovered"] as? Bool==true);#expect(try Data(contentsOf:entry.store.file.url)==before)
    }
    @Test func registryMatchesSchemasAndWritesCoverageArtifact() throws {
        let operations=MCPRegistry.operations
        #expect(Set(operations.map(\.name)).count==operations.count)
        #expect(operations.allSatisfy{!$0.writes || $0.required.contains("idempotencyKey")})
        #expect(operations.filter { $0.confirmation }.allSatisfy { $0.writes })
        try MCPJSON.data(operations.map{["tool":$0.tool,"permission":$0.permission?.rawValue ?? "discovery","writes":$0.writes,"confirmation":$0.confirmation]}).write(to:URL(fileURLWithPath:"/private/tmp/Foldpin-mcp-operations.json"),options:.atomic)
    }

}
