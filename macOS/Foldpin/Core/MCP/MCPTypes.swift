import Foundation
import CryptoKit
import Security

@MainActor
enum MCPJSON {
    static func data(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed]) }
    static func object<T: Encodable>(_ value: T) throws -> Any { try JSONSerialization.jsonObject(with: JSONEncoder().encode(value), options: .fragmentsAllowed) }
    static func decode<T: Decodable>(_ type: T.Type, _ value: Any) throws -> T { try JSONDecoder().decode(type, from: data(value)) }
    static func hash(_ value: Any) throws -> String { SHA256.hash(data: try data(value)).map { String(format: "%02x", $0) }.joined() }
    static func revision(_ document: NoteDocument) throws -> String { try hash(object(document)) }
    static func secret() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw MCPFailure("credential_unavailable") }
        return Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}
nonisolated struct MCPFailure: Error, LocalizedError {
    let code: String
    init(_ code: String) { self.code = code }
    var errorDescription: String? { code }
}
nonisolated enum MCPPermission: String, Codable, CaseIterable, Sendable {
    case read, assets, create, edit, collections, windows, trash, purge, clipboardRead, clipboardWrite, media, recording, export, settings, storage, external, application
}
nonisolated struct MCPGrant: Codable, Identifiable, Sendable {
    var id = UUID()
    var name: String
    var libraryID: String
    var permissions: Set<MCPPermission>
    /// nil means all notes in this exact library, never all future libraries.
    var noteIDs: Set<UUID>?
    var collectionIDs: Set<UUID> = []
    var createdAt = Date()
}
@MainActor
extension Dictionary where Key == String, Value == Any {
    func string(_ key: String) throws -> String { guard let value = self[key] as? String else { throw MCPFailure("invalid_input") }; return value }
    func uuid(_ key: String) throws -> UUID { guard let value = UUID(uuidString: try string(key)) else { throw MCPFailure("invalid_input") }; return value }
    func strings(_ key: String) throws -> [String] { guard let values = self[key] as? [String] else { throw MCPFailure("invalid_input") }; return values }
    func int(_ key: String, default fallback: Int = 0) -> Int { (self[key] as? NSNumber)?.intValue ?? fallback }
    func bool(_ key: String, default fallback: Bool = false) -> Bool { self[key] as? Bool ?? fallback }
}

/// Durable receipt before execution. An interrupted write is never blindly replayed.
@MainActor
final class MCPJournal {
    struct Receipt: Codable {
        var operationID: UUID
        var fingerprint: String
        var client: UUID
        var libraryID: String
        var tool: String
        var status: String
        var createdAt = Date()
        var result: Data?
        var createdNoteID: UUID?
        var editedNoteID: UUID?
        var expectedContentHash: String?
    }
    let directory: URL
    init(directory: URL) { self.directory = directory }
    func key(client: UUID, key: String) -> String { SHA256.hash(data: Data((client.uuidString + ":" + key).utf8)).map { String(format: "%02x", $0) }.joined() }
    func read(_ key: String) throws -> Receipt? {
        let url = directory.appendingPathComponent(key + ".json")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(Receipt.self, from: Data(contentsOf: url))
    }
    func write(_ receipt: Receipt, key: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(receipt).write(to: directory.appendingPathComponent(key + ".json"), options: [.atomic, .completeFileProtectionUnlessOpen])
    }
}
