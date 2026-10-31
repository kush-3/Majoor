// ClientCredentials.swift
// Majoor — What a client remembers about the runtime it paired with
//
// Host, port, client id and the runtime id live in UserDefaults; the bearer
// token lives in the Keychain (PRD §12: "pairing token in Keychain").

import Foundation

nonisolated struct ClientCredentials: Sendable, Equatable {
    var host: String
    var port: UInt16
    var clientId: String
    var token: String
    /// Learned from the first `hello.ok`; a later mismatch means the address
    /// now points at a different machine and the client warns loudly.
    var runtimeId: String?
}

nonisolated enum ClientCredentialsStore {
    static let hostKey = "clientRuntimeHost"
    static let portKey = "clientRuntimePort"
    static let clientIdKey = "clientId"
    static let runtimeIdKey = "clientRuntimeId"
    static let tokenKeychainKey = "controlClientToken"

    static func load(defaults: UserDefaults = .standard, keychain: KeychainManager = .shared) -> ClientCredentials? {
        guard let host = defaults.string(forKey: hostKey), !host.isEmpty,
              let clientId = defaults.string(forKey: clientIdKey), !clientId.isEmpty,
              let token = keychain.retrieve(key: tokenKeychainKey), !token.isEmpty else { return nil }
        let storedPort = defaults.integer(forKey: portKey)
        let port = (1...65535).contains(storedPort) ? UInt16(storedPort) : ControlProtocol.defaultPort
        return ClientCredentials(host: host, port: port, clientId: clientId, token: token,
                                 runtimeId: defaults.string(forKey: runtimeIdKey))
    }

    static func save(_ credentials: ClientCredentials, defaults: UserDefaults = .standard, keychain: KeychainManager = .shared) {
        defaults.set(credentials.host, forKey: hostKey)
        defaults.set(Int(credentials.port), forKey: portKey)
        defaults.set(credentials.clientId, forKey: clientIdKey)
        defaults.set(credentials.runtimeId, forKey: runtimeIdKey)
        keychain.save(key: tokenKeychainKey, value: credentials.token)
    }

    static func saveRuntimeId(_ runtimeId: String, defaults: UserDefaults = .standard) {
        defaults.set(runtimeId, forKey: runtimeIdKey)
    }

    static func forget(defaults: UserDefaults = .standard, keychain: KeychainManager = .shared) {
        for key in [hostKey, portKey, clientIdKey, runtimeIdKey] { defaults.removeObject(forKey: key) }
        keychain.delete(key: tokenKeychainKey)
    }
}
