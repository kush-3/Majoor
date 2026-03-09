// KeychainManager.swift
// Majoor — Keychain Manager
//
// Stores API keys securely in the macOS Keychain.

import Foundation
import Security

// This class runs nonisolated since it only touches Keychain (thread-safe C API)
nonisolated class KeychainManager: @unchecked Sendable {
    
    static let shared = KeychainManager()
    
    private let serviceName = "com.majoor.agent"
    
    private init() {}
    
    enum APIKeyType: String, Sendable {
        case anthropic = "anthropic-api-key"
        case openai = "openai-api-key"
    }
    
    func saveAPIKey(_ key: String, for type: APIKeyType) -> Bool {
        guard let data = key.data(using: .utf8) else { return false }
        
        deleteAPIKey(for: type)
        
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: type.rawValue,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        
        let status = SecItemAdd(query as CFDictionary, nil)
        MajoorLogger.log(status == errSecSuccess ? "✅ API key saved" : "❌ Failed to save API key: \(status)")
        return status == errSecSuccess
    }
    
    func getAPIKey(for type: APIKeyType) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: type.rawValue,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        
        var dataRef: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &dataRef)
        
        guard status == errSecSuccess,
              let data = dataRef as? Data,
              let key = String(data: data, encoding: .utf8) else {
            return nil
        }
        return key
    }
    
    @discardableResult
    func deleteAPIKey(for type: APIKeyType) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: type.rawValue
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
    
    func hasAPIKey(for type: APIKeyType) -> Bool {
        return getAPIKey(for: type) != nil
    }
}
