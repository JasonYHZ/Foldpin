import AppKit
import SwiftUI
import Testing
@testable import FoldpinCore

@Test @MainActor func mcpNativeEditorUndoCompositionAndSettings() async throws {
    let root=URL(fileURLWithPath:ProcessInfo.processInfo.environment["FOLDPIN_CHECK_DATA"]!).appendingPathComponent(UUID().uuidString)
    let output=URL(fileURLWithPath:ProcessInfo.processInfo.environment["FOLDPIN_CHECK_OUTPUT"]!)
    let library=NoteLibrary(directory:root.appendingPathComponent("library"),localDirectory:root.appendingPathComponent("local"),createsInitialNote:false)
    var document=NoteDocument();document.text="Before AI edit";document.isShelved=true
    let entry=try library.importDocument(document)
    let paper=PaperWindowController(entry:entry,initialFrame:NSRect(x:0,y:0,width:520,height:600));defer{paper.dispose()}
    let editor=paper.session.host.editor,history=try #require(editor.undoManager)
    let service=FoldpinCommandService(library:{library},journal:MCPJournal(directory:root.appendingPathComponent("receipts")))
    let grant=MCPGrant(name:"Native test",libraryID:service.libraryID,permissions:[.read,.edit],noteIDs:nil)
    service.isBusy={_ in editor.mcpInteractionBusy}
    service.commitContent={e,c in try editor.applyCommandContent(c);guard e.store.flush() else{throw MCPFailure("save_failed")}}
    #expect(entry.store.flush())
    history.beginUndoGrouping()
    let result=await service.invoke("foldpin_update_note",args:["libraryId":service.libraryID,"noteId":entry.id.uuidString,"expectedRevision":try MCPJSON.revision(entry.store.document),"idempotencyKey":"edit","text":"After AI edit"],grant:grant)
    history.endUndoGrouping()
    #expect(result["status"] as? String == "completed", Comment(rawValue:result["error"] as? String ?? ""))
    #expect(editor.string=="After AI edit");#expect(editor.undoManager === history);#expect(!paper.paper.isVisible)
    history.undo();editor.commitContent();#expect(editor.string=="Before AI edit");#expect(entry.store.flush())
    editor.setSelectedRange(NSRange(location:0,length:0))
    editor.setMarkedText("中文组合",selectedRange:NSRange(location:4,length:0),replacementRange:editor.selectedRange())
    #expect(editor.hasMarkedText())
    let composing=editor.string
    let busy=await service.invoke("foldpin_update_note",args:["libraryId":service.libraryID,"noteId":entry.id.uuidString,"expectedRevision":try MCPJSON.revision(entry.store.document),"idempotencyKey":"ime","text":"Must not overwrite"],grant:grant)
    #expect(busy["error"] as? String=="busy_editing");#expect(editor.hasMarkedText());#expect(editor.string==composing)
    editor.unmarkText()
    let suite="Foldpin.MCP.UI."+UUID().uuidString
    let defaults=UserDefaults(suiteName:suite)!
    defer{defaults.removePersistentDomain(forName:suite)}
    let server=MCPServer(commands:service,defaults:defaults)
    let view=NSHostingView(rootView:MCPSettingsView(server:server))
    let window=NSWindow(contentRect:NSRect(x:0,y:0,width:680,height:540),styleMask:[.titled],backing:.buffered,defer:false)
    window.isReleasedWhenClosed=false;window.contentView=view
    for _ in 0..<8{try await Task.sleep(for:.milliseconds(25));view.layoutSubtreeIfNeeded()}
    #expect(!server.enabled);#expect(!window.isVisible)
    if let bitmap=view.bitmapImageRepForCachingDisplay(in:view.bounds){view.cacheDisplay(in:view.bounds,to:bitmap);try bitmap.representation(using:.png,properties:[:])?.write(to:output.appendingPathComponent("mcp-settings.png"))}
    window.contentView=nil;window.close()
}
