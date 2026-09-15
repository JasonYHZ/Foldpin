import Foundation
import Testing
@testable import FoldpinCore

@Suite @MainActor struct MCPCompatibilityTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["FOLDPIN_MCP_SDK_CHECK"] == "1"))
    func officialSDKs() async throws {
        final class Credentials: MCPCredentialStore {
            var values:[UUID:String]=[:]
            func set(_ token:String,client:UUID)throws{values[client]=token}
            func get(client:UUID)throws->String?{values[client]}
            func remove(client:UUID)throws{values.removeValue(forKey:client)}
        }
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("Foldpin.MCP.SDK."+UUID().uuidString)
        let suite="Foldpin.MCP.SDK."+UUID().uuidString
        let defaults=UserDefaults(suiteName:suite)!
        defer{try? FileManager.default.removeItem(at:root);defaults.removePersistentDomain(forName:suite)}
        let library=NoteLibrary(directory:root.appendingPathComponent("library"),localDirectory:root.appendingPathComponent("local"),createsInitialNote:false)
        let commands=FoldpinCommandService(library:{library},journal:MCPJournal(directory:root.appendingPathComponent("receipts")))
        let server=MCPServer(commands:commands,defaults:defaults,credentials:Credentials());server.port=53179
        let token=try server.addClient(name:"SDK checks",permissions:Set(MCPPermission.allCases),noteIDs:nil)
        let config=root.appendingPathComponent("client.json")
        try MCPJSON.data(["endpoint":server.endpoint,"token":token,"libraryId":commands.libraryID]).write(to:config)
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:config.path)
        server.setEnabled(true);defer{server.stop()}
        try await Task.sleep(for:.milliseconds(300))
        try #require(server.enabled, Comment(rawValue:server.error ?? "Listener stopped"))
        let repository=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let scripts=repository.appendingPathComponent("scripts/checks")
        let commandsToRun=[
            ("/private/tmp/foldpin-mcp-python/bin/python",[scripts.appendingPathComponent("mcp-client-python.py").path,config.path]),
            ("/usr/bin/env",["node",scripts.appendingPathComponent("mcp-client-typescript.mjs").path,config.path,"/private/tmp/foldpin-mcp-compat/node_modules/@modelcontextprotocol/sdk"])
        ]
        for (executable,arguments) in commandsToRun {
            let process=Process();process.executableURL=URL(fileURLWithPath:executable);process.arguments=arguments
            let output=Pipe();process.standardOutput=output;process.standardError=output;try process.run()
            let deadline=Date().addingTimeInterval(45)
            while process.isRunning, Date()<deadline {try await Task.sleep(for:.milliseconds(50))}
            if process.isRunning{process.terminate()}
            while process.isRunning{try await Task.sleep(for:.milliseconds(20))}
            let text=String(decoding:output.fileHandleForReading.readDataToEndOfFile(),as:UTF8.self)
            #expect(process.terminationStatus==0,Comment(rawValue:text))
            if process.terminationStatus==0{print(text)}
        }
        #expect(library.entries.count==2)
    }
}
