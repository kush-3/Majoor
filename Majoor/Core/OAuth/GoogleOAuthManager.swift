// GoogleOAuthManager.swift
// Majoor — Google OAuth 2.0 Flow for Gmail
//
// Uses a temporary loopback HTTP server (127.0.0.1) for the OAuth redirect.
// Google requires Desktop apps to use loopback redirects, not custom URL schemes.
// Stores tokens in Keychain via KeychainManager.

import Foundation
import AppKit

nonisolated final class GoogleOAuthManager: NSObject, @unchecked Sendable {

    static let shared = GoogleOAuthManager()

    private let tokenURL = "https://oauth2.googleapis.com/token"
    private let authURL = "https://accounts.google.com/o/oauth2/v2/auth"
    private let scopes = "https://www.googleapis.com/auth/gmail.modify email"

    // Token keys for Keychain
    private static let accessTokenKey = "google_access_token"
    private static let refreshTokenKey = "google_refresh_token"
    private static let tokenExpiryKey = "google_token_expiry"
    private static let userEmailKey = "google_user_email"

    private override init() { super.init() }

    // MARK: - Public API

    /// Check if user is authenticated (has a refresh token)
    var isAuthenticated: Bool {
        KeychainManager.shared.retrieve(key: Self.refreshTokenKey) != nil
    }

    /// Get the connected email address, if available
    var connectedEmail: String? {
        KeychainManager.shared.retrieve(key: Self.userEmailKey)
    }

    /// Start the OAuth flow. Opens system browser for Google sign-in.
    /// Spins up a temporary loopback HTTP server to receive the callback.
    /// Returns the user's email on success.
    func authorize() async throws -> String {
        // 1. Create loopback server
        let (serverSocket, port) = try createLoopbackServer()
        let redirectURI = "http://127.0.0.1:\(port)"

        // 2. Build authorization URL
        var components = URLComponents(string: authURL)!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: APIConfig.googleClientId),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: scopes),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent"),
        ]

        let authorizationURL = components.url!

        // 3. Open in default browser
        await MainActor.run {
            NSWorkspace.shared.open(authorizationURL)
        }

        MajoorLogger.log("OAuth: opened browser, waiting for callback on port \(port)")

        // 4. Wait for the authorization code
        let code = try await waitForOAuthCode(port: port, serverSocket: serverSocket)

        // 5. Exchange code for tokens
        let tokens = try await exchangeCodeForTokens(code, redirectURI: redirectURI)

        // 6. Fetch user email
        let email = try await fetchUserEmail(accessToken: tokens.accessToken)

        // 7. Store everything
        storeTokens(tokens, email: email)

        MajoorLogger.log("✅ Google OAuth complete for \(email)")
        return email
    }

    /// Get a valid access token, refreshing if expired.
    func validAccessToken() async throws -> String {
        // Check if current token is still valid
        if let token = KeychainManager.shared.retrieve(key: Self.accessTokenKey),
           let expiryStr = KeychainManager.shared.retrieve(key: Self.tokenExpiryKey),
           let expiryInterval = TimeInterval(expiryStr),
           Date().timeIntervalSince1970 < expiryInterval - 60 {
            return token
        }

        // Need to refresh
        guard let refreshToken = KeychainManager.shared.retrieve(key: Self.refreshTokenKey) else {
            throw OAuthError.notAuthenticated
        }

        let tokens = try await refreshAccessToken(refreshToken)
        storeTokens(tokens, email: nil)
        return tokens.accessToken
    }

    /// Disconnect — revoke and clear all tokens
    func disconnect() {
        if let token = KeychainManager.shared.retrieve(key: Self.accessTokenKey) {
            Task {
                var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/revoke?token=\(token)")!)
                request.httpMethod = "POST"
                _ = try? await URLSession.shared.data(for: request)
            }
        }
        KeychainManager.shared.delete(key: Self.accessTokenKey)
        KeychainManager.shared.delete(key: Self.refreshTokenKey)
        KeychainManager.shared.delete(key: Self.tokenExpiryKey)
        KeychainManager.shared.delete(key: Self.userEmailKey)
        MajoorLogger.log("Google account disconnected")
    }

    // MARK: - Loopback HTTP Server

    /// Waits for the OAuth callback on a loopback HTTP server.
    /// Returns the authorization code.
    private func waitForOAuthCode(port: UInt16, serverSocket: Int32) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let clientSocket = accept(serverSocket, nil, nil)
                defer {
                    close(clientSocket)
                    close(serverSocket)
                }

                guard clientSocket >= 0 else {
                    continuation.resume(throwing: OAuthError.loopbackServerFailed("accept() failed"))
                    return
                }

                var buffer = [UInt8](repeating: 0, count: 4096)
                let bytesRead = recv(clientSocket, &buffer, buffer.count, 0)
                guard bytesRead > 0 else {
                    continuation.resume(throwing: OAuthError.loopbackServerFailed("recv() failed"))
                    return
                }

                let requestString = String(bytes: buffer[0..<bytesRead], encoding: .utf8) ?? ""

                guard let firstLine = requestString.components(separatedBy: "\r\n").first,
                      let urlPart = firstLine.split(separator: " ").dropFirst().first,
                      let urlComponents = URLComponents(string: String(urlPart)) else {
                    continuation.resume(throwing: OAuthError.noCodeReturned)
                    return
                }

                if let error = urlComponents.queryItems?.first(where: { $0.name == "error" })?.value {
                    let htmlResponse = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nConnection: close\r\n\r\n<html><body style=\"font-family:system-ui;text-align:center;padding-top:60px;\"><h2>Authorization Failed</h2><p>\(error)</p><p style=\"color:#666;\">You can close this tab.</p></body></html>"
                    _ = htmlResponse.withCString { send(clientSocket, $0, strlen($0), 0) }
                    continuation.resume(throwing: OAuthError.userDenied(error))
                    return
                }

                guard let code = urlComponents.queryItems?.first(where: { $0.name == "code" })?.value else {
                    continuation.resume(throwing: OAuthError.noCodeReturned)
                    return
                }

                let htmlResponse = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nConnection: close\r\n\r\n<html><body style=\"font-family:system-ui;text-align:center;padding-top:60px;\"><h2>Connected to Majoor</h2><p>You can close this tab and return to the app.</p></body></html>"
                _ = htmlResponse.withCString { send(clientSocket, $0, strlen($0), 0) }

                continuation.resume(returning: code)
            }
        }
    }

    /// Creates a loopback TCP server socket bound to 127.0.0.1 on a random port.
    /// Returns (serverSocket, port).
    private nonisolated func createLoopbackServer() throws -> (socket: Int32, port: UInt16) {
        let serverSocket = socket(AF_INET, SOCK_STREAM, 0)
        guard serverSocket >= 0 else { throw OAuthError.loopbackServerFailed("socket() failed") }

        var opt: Int32 = 1
        setsockopt(serverSocket, SOL_SOCKET, SO_REUSEADDR, &opt, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.bind(serverSocket, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            close(serverSocket)
            throw OAuthError.loopbackServerFailed("bind() failed: \(errno)")
        }

        guard listen(serverSocket, 1) == 0 else {
            close(serverSocket)
            throw OAuthError.loopbackServerFailed("listen() failed")
        }

        var assignedAddr = sockaddr_in()
        var addrLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &assignedAddr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                getsockname(serverSocket, sockPtr, &addrLen)
            }
        }
        let port = UInt16(bigEndian: assignedAddr.sin_port)

        return (serverSocket, port)
    }

    // MARK: - Token Exchange

    private struct TokenResponse: Codable {
        let access_token: String
        let expires_in: Int
        let refresh_token: String?
        let token_type: String
    }

    private struct Tokens {
        let accessToken: String
        let refreshToken: String?
        let expiresIn: Int
    }

    private func exchangeCodeForTokens(_ code: String, redirectURI: String) async throws -> Tokens {
        var request = URLRequest(url: URL(string: tokenURL)!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let body = [
            "code": code,
            "client_id": APIConfig.googleClientId,
            "client_secret": APIConfig.googleClientSecret,
            "redirect_uri": redirectURI,
            "grant_type": "authorization_code",
        ]
        request.httpBody = body.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? $0.value)" }
            .joined(separator: "&").data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let errBody = String(data: data, encoding: .utf8) ?? "unknown"
            throw OAuthError.tokenExchangeFailed(errBody)
        }

        let tokenResponse = try JSONDecoder().decode(TokenResponse.self, from: data)
        return Tokens(
            accessToken: tokenResponse.access_token,
            refreshToken: tokenResponse.refresh_token,
            expiresIn: tokenResponse.expires_in
        )
    }

    private func refreshAccessToken(_ refreshToken: String) async throws -> Tokens {
        var request = URLRequest(url: URL(string: tokenURL)!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let body = [
            "refresh_token": refreshToken,
            "client_id": APIConfig.googleClientId,
            "client_secret": APIConfig.googleClientSecret,
            "grant_type": "refresh_token",
        ]
        request.httpBody = body.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? $0.value)" }
            .joined(separator: "&").data(using: .utf8)

        let maxAttempts = 2
        for attempt in 1...maxAttempts {
            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await URLSession.shared.data(for: request)
            } catch {
                if attempt < maxAttempts {
                    try await Task.sleep(for: .seconds(2))
                    continue
                }
                throw OAuthError.refreshFailed(error.localizedDescription)
            }

            guard let httpResponse = response as? HTTPURLResponse else {
                throw OAuthError.refreshFailed("Invalid response")
            }

            switch httpResponse.statusCode {
            case 200:
                let tokenResponse = try JSONDecoder().decode(TokenResponse.self, from: data)
                return Tokens(
                    accessToken: tokenResponse.access_token,
                    refreshToken: tokenResponse.refresh_token ?? refreshToken,
                    expiresIn: tokenResponse.expires_in
                )
            case 400, 401:
                disconnect()
                throw OAuthError.notAuthenticated
            default:
                if attempt < maxAttempts {
                    try await Task.sleep(for: .seconds(2))
                    continue
                }
                let errBody = String(data: data, encoding: .utf8) ?? "unknown"
                throw OAuthError.refreshFailed(errBody)
            }
        }

        throw OAuthError.refreshFailed("Retry attempts exhausted")
    }

    // MARK: - User Info

    private func fetchUserEmail(accessToken: String) async throws -> String {
        var request = URLRequest(url: URL(string: "https://www.googleapis.com/oauth2/v2/userinfo")!)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        let (data, _) = try await URLSession.shared.data(for: request)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let email = json?["email"] as? String else {
            throw OAuthError.noEmailReturned
        }
        return email
    }

    // MARK: - Storage

    private func storeTokens(_ tokens: Tokens, email: String?) {
        MajoorLogger.log("Storing tokens — access: \(tokens.accessToken.count) chars, refresh: \(tokens.refreshToken?.count ?? 0) chars, expiresIn: \(tokens.expiresIn)")
        KeychainManager.shared.save(key: Self.accessTokenKey, value: tokens.accessToken)
        if let refresh = tokens.refreshToken {
            KeychainManager.shared.save(key: Self.refreshTokenKey, value: refresh)
        } else {
            MajoorLogger.log("⚠️ No refresh token received — isAuthenticated will return false!")
        }
        let expiry = Date().timeIntervalSince1970 + Double(tokens.expiresIn)
        KeychainManager.shared.save(key: Self.tokenExpiryKey, value: String(expiry))
        if let email {
            KeychainManager.shared.save(key: Self.userEmailKey, value: email)
        }
        // Verify storage
        let verified = KeychainManager.shared.retrieve(key: Self.refreshTokenKey) != nil
        MajoorLogger.log("Token storage verified — isAuthenticated: \(verified)")
    }
}

// MARK: - Errors

enum OAuthError: LocalizedError {
    case noCodeReturned
    case tokenExchangeFailed(String)
    case refreshFailed(String)
    case notAuthenticated
    case noEmailReturned
    case loopbackServerFailed(String)
    case userDenied(String)

    var errorDescription: String? {
        switch self {
        case .noCodeReturned: return "No authorization code returned from Google."
        case .tokenExchangeFailed(let d): return "Token exchange failed: \(d)"
        case .refreshFailed(let d): return "Token refresh failed: \(d)"
        case .notAuthenticated: return "Not authenticated with Google. Connect your account in Settings > Accounts."
        case .noEmailReturned: return "Could not retrieve email from Google."
        case .loopbackServerFailed(let d): return "OAuth server failed: \(d)"
        case .userDenied(let d): return "Authorization denied: \(d)"
        }
    }
}
