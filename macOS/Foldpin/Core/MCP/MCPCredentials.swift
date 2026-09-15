import Foundation
import Security
import LocalAuthentication

@MainActor
protocol MCPCredentialStore {
    func set(_ token:String,client:UUID) throws
    func get(client:UUID) throws -> String?
    func remove(client:UUID) throws
}
@MainActor
final class MCPKeychain:MCPCredentialStore {
    private let service="dev.jasonyu.Foldpin.mcp"
    private func query(_ id:UUID)->[String:Any]{[kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:service,kSecAttrAccount as String:id.uuidString]}
    func set(_ token:String,client:UUID) throws {
        let q=query(client),data=Data(token.utf8)
        let status=SecItemUpdate(q as CFDictionary,[kSecValueData as String:data] as CFDictionary)
        if status == errSecItemNotFound {
            var add=q;add[kSecValueData as String]=data;add[kSecAttrAccessible as String]=kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            guard SecItemAdd(add as CFDictionary,nil)==errSecSuccess else{throw MCPFailure("credential_unavailable")}
        }else if status != errSecSuccess{throw MCPFailure("credential_unavailable")}
    }
    func get(client:UUID) throws -> String? {
        var q=query(client);q[kSecReturnData as String]=true;q[kSecMatchLimit as String]=kSecMatchLimitOne
        let context = LAContext(); context.interactionNotAllowed = true
        q[kSecUseAuthenticationContext as String] = context
        var result:CFTypeRef?;let status=SecItemCopyMatching(q as CFDictionary,&result)
        if status==errSecItemNotFound{return nil}
        guard status==errSecSuccess,let data=result as? Data,let token=String(data:data,encoding:.utf8) else{throw MCPFailure("credential_unavailable")};return token
    }
    func remove(client:UUID) throws {let status=SecItemDelete(query(client) as CFDictionary);guard status==errSecSuccess || status==errSecItemNotFound else{throw MCPFailure("credential_unavailable")}}
}
