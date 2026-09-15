import SwiftUI
import AppKit

@MainActor func mcpText(_ key:String)->String{LanguageSettings.shared.bundle.localizedString(forKey:key,value:key,table:nil)}

struct MCPSettingsView:View {
    @ObservedObject var server:MCPServer
    @ObservedObject private var language=LanguageSettings.shared
    @State private var adding=false
    @State private var revealedToken:String?
    @State private var pendingToken:String?
    var body:some View{
        Form{
            Section{
                Toggle(mcpText("Enable MCP connections"),isOn:Binding(get:{server.enabled},set:{server.setEnabled($0)}))
                Text(mcpText("Allow AI tools you authorize to work with Foldpin. The service runs only on this Mac and stops when Foldpin quits.")).font(.caption).foregroundStyle(.secondary)
                HStack{Text(mcpText("Port"));Spacer();TextField("",value:$server.port,format:.number.grouping(.never)).labelsHidden().textFieldStyle(.roundedBorder).frame(width:90).disabled(server.enabled)}
                LabeledContent(mcpText("Connection address")){Text(server.endpoint).font(.system(.caption,design:.monospaced)).textSelection(.enabled)}
                Text(mcpText("Streamable HTTP · Bearer authorization header · protocol 2025-11-25. OAuth and stdio-only clients are not supported.")).font(.caption).foregroundStyle(.secondary)
                if let error=server.error{Text(mcpText(error)).foregroundStyle(.red)}
            }
            Section(mcpText("Authorized clients")){
                ForEach(server.grants){grant in
                    HStack{
                        VStack(alignment:.leading){Text(grant.name);Text(grant.libraryID == server.commands.libraryID ? mcpText("Current library") : mcpText("Another library")).font(.caption).foregroundStyle(.secondary)}
                        Spacer()
                        Button(mcpText("Rotate key")){do{revealedToken=try server.rotate(grant.id)}catch{server.error="Could not save the client key in Keychain."}}
                        Button(mcpText("Revoke"),role:.destructive){server.revoke(grant.id)}
                    }
                }
                Button(mcpText("Authorize a client…")){adding=true}
            }
            Section(mcpText("Recent calls")){
                ForEach(server.calls.prefix(8)){call in HStack{Text(call.client);Text(call.tool).font(.caption).lineLimit(1);Spacer();Text(mcpText(call.status)).font(.caption).foregroundStyle(.secondary)}}
                Button(mcpText("Clear call history")){server.clearCalls()}
                Text(mcpText("Call history stays in memory and contains no note content, file paths or access keys.")).font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped)
        .sheet(isPresented:$adding,onDismiss:{revealedToken=pendingToken;pendingToken=nil}){MCPGrantView(server:server,onToken:{pendingToken=$0;adding=false})}
        .sheet(isPresented:Binding(get:{revealedToken != nil},set:{if !$0{revealedToken=nil}})){
            VStack(alignment:.leading,spacing:16){
                Text(mcpText("Save this access key")).font(.title2)
                Text(mcpText("Shown only now. Paste it into your client's Authorization header as Bearer followed by a space and this key. Keep it private."))
                Text(revealedToken ?? "").font(.system(.body,design:.monospaced)).textSelection(.enabled)
                HStack{Spacer();Button(mcpText("Done")){revealedToken=nil}.keyboardShortcut(.defaultAction)}
            }.padding(24).frame(width:520)
        }
    }
}
private struct MCPGrantView:View{
    @ObservedObject var server:MCPServer
    let onToken:(String)->Void
    @Environment(\.dismiss) private var dismiss
    @State private var name=""
    @State private var permissions:Set<MCPPermission>=[.read]
    @State private var allNotes=true
    @State private var notes:Set<UUID>=[]
    @State private var collections:Set<UUID>=[]
    @State private var error:String?
    var body:some View{
        VStack(alignment:.leading,spacing:12){
            Text(mcpText("Authorize a client")).font(.title2)
            TextField(mcpText("Client name"),text:$name)
            Text(mcpText("Reading notes may send their contents to the external AI service configured in your client. MCP does not guarantee offline inference.")).font(.caption).foregroundStyle(.secondary)
            Toggle(mcpText("All notes in the current library"),isOn:$allNotes)
            ScrollView{
                VStack(alignment:.leading,spacing:8){
                    if !allNotes{
                        Text(mcpText("Creating notes, managing collections and library-wide actions require authorization for all notes.")).font(.caption).foregroundStyle(.secondary)
                        ForEach(server.commands.library().entries){entry in
                            Toggle(entry.store.document.summary(bundle:LanguageSettings.shared.bundle),isOn:Binding(get:{notes.contains(entry.id)},set:{if $0{notes.insert(entry.id)}else{notes.remove(entry.id)}})).lineLimit(1)
                        }
                        ForEach(server.commands.collections().collections){collection in
                            Toggle(mcpText("Collection")+": "+collection.name,isOn:Binding(get:{collections.contains(collection.id)},set:{if $0{collections.insert(collection.id)}else{collections.remove(collection.id)}}))
                        }
                    }
                    Divider()
                    ForEach(MCPPermission.allCases,id:\.rawValue){permission in
                        Toggle(mcpText("MCP permission: "+permission.rawValue),isOn:Binding(get:{permissions.contains(permission)},set:{if $0{permissions.insert(permission)}else{permissions.remove(permission)}}))
                    }
                }
            }.frame(height:260)
            Text(mcpText("Permanent deletion, recording, external files and quitting still require confirmation here. Authorization cannot be changed by AI tools.")).font(.caption).foregroundStyle(.secondary)
            if let error{Text(mcpText(error)).foregroundStyle(.red)}
            HStack{Button(mcpText("Cancel")){dismiss()};Spacer();Button(mcpText("Authorize")){do{onToken(try server.addClient(name:name,permissions:permissions,noteIDs:allNotes ? nil : notes,collectionIDs:collections))}catch{self.error="Could not save the client key in Keychain."}}.disabled(name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty || (!allNotes && notes.isEmpty && collections.isEmpty))}
        }.padding(24).frame(width:520)
    }
}
@MainActor
final class MCPApprovalCenter {
    private var windows:[UUID:MCPApprovalWindow]=[:]
    func show(id:UUID,name:String,args:[String:Any],grant:MCPGrant,service:FoldpinCommandService){
        guard windows.count<8 else{service.reject(id);return}
        var ids: [UUID] = []
        if let value=args["noteId"] as? String,let id=UUID(uuidString:value){ids.append(id)}
        if let targets=args["targets"] as? [[String:Any]]{ids += targets.compactMap{($0["noteId"] as? String).flatMap(UUID.init(uuidString:))}}
        let titles=ids.compactMap{try? service.entry($0,grant).store.document.summary(bundle:LanguageSettings.shared.bundle)}
        var lines=titles.map{"• " + String($0.prefix(160))}
        if let id=ids.first,let blockID=(args["blockId"] as? String).flatMap(UUID.init(uuidString:)),
           let entry=try? service.entry(id,grant),let block=entry.store.document.content.blocks.first(where:{$0.id==blockID}),
           let name=block.attachment?.name ?? block.image?.name ?? block.audio?.name ?? block.video?.name {
            lines.append("• " + String(name.prefix(200)))
        }
        if let format=args["format"] as? String{lines.append(mcpText("Format")+": "+format.uppercased())}
        if let enabled=args["enabled"] as? Bool{lines.append(mcpText(enabled ? "Enable launch at login" : "Disable launch at login"))}
        if let action=args["action"] as? String{lines.append(mcpText("MCP location action: "+action))}
        if lines.isEmpty{lines.append(mcpText("Follow the local system dialog to choose the file or approve the action."))}
        let pretty=lines.joined(separator:"\n")
        let controller=MCPApprovalWindow(title:grant.name,operation:name,details:pretty){[weak self] approved in
            self?.windows.removeValue(forKey:id)
            if approved{Task{await service.approve(id)}}else{service.reject(id)}
        }
        windows[id]=controller;controller.showWindow(nil);NSApp.activate();controller.window?.makeKeyAndOrderFront(nil)
    }
}
@MainActor private final class MCPApprovalWindow:NSWindowController,NSWindowDelegate{
    private var response:((Bool)->Void)?
    init(title:String,operation:String,details:String,response:@escaping(Bool)->Void){
        self.response=response
        let window=NSWindow(contentRect:NSRect(x:0,y:0,width:520,height:400),styleMask:[.titled,.closable],backing:.buffered,defer:false)
        window.title=mcpText("AI tool requests approval");window.isReleasedWhenClosed=false
        super.init(window:window);window.delegate=self
        window.contentView=NSHostingView(rootView:VStack(alignment:.leading,spacing:16){
            Text(mcpText("AI tool requests approval")).font(.title2)
            Text(title).font(.headline);Text(mcpText("MCP action: "+operation)).font(.headline)
            Text(operation).font(.system(.caption,design:.monospaced)).foregroundStyle(.secondary)
            ScrollView{Text(details).font(.system(.caption,design:.monospaced)).frame(maxWidth:.infinity,alignment:.leading).textSelection(.enabled)}
            Text(mcpText("Only these targets will be used. Changes made after this request will cancel the operation.")).font(.caption).foregroundStyle(.secondary)
            HStack{Button(mcpText("Deny")){[weak self] in self?.finish(false)};Spacer();Button(mcpText("Allow once")){[weak self] in self?.finish(true)}}
        }.padding(24))
        window.center()
    }
    required init?(coder:NSCoder){nil}
    func windowWillClose(_ notification:Notification){finish(false)}
    private func finish(_ approved:Bool){guard let response else{return};self.response=nil;close();response(approved)}
}
