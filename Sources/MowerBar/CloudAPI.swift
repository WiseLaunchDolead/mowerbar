import Foundation
import Security
import MowerBarCore

struct SessionToken: Codable {
    var accessToken: String, refreshToken: String
    var expiresAt: Date
    static func parse(_ data: Data) throws -> SessionToken {
        guard let v = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = v["access_token"] as? String, let refresh = v["refresh_token"] as? String,
              !access.isEmpty, !refresh.isEmpty, (v["token_type"] as? String ?? "Bearer").lowercased() == "bearer" else {
            throw ProtocolError.invalid(String(localized: "The Worx session received is invalid."))
        }
        let retrieved = parseCloudDate(v["retrieved_at"] as? String) ?? Date()
        var expires = retrieved.addingTimeInterval(v["expires_in"] as? Double ?? 3600)
        let parts = access.split(separator: ".")
        if parts.count == 3 {
            var base = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            base += String(repeating: "=", count: (4-base.count%4)%4)
            if let d = Data(base64Encoded: base), let claims = try? JSONSerialization.jsonObject(with: d) as? [String: Any], let exp = claims["exp"] as? Double {
                expires = Date(timeIntervalSince1970: exp)
            }
        }
        return SessionToken(accessToken: access, refreshToken: refresh, expiresAt: expires)
    }
}

enum SecureSession {
    /// One Keychain item per app identity; nothing is shared with other apps or written to disk.
    private static let service = Bundle.main.bundleIdentifier ?? "io.github.wiselaunchdolead.mowerbar"
    private static var query: [String: Any] { [kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service, kSecAttrAccount as String: "worx-session"] }
    static func load() throws -> SessionToken? {
        var q = query; q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?; let status = SecItemCopyMatching(q as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else { throw ProtocolError.invalid(String(localized: "The macOS Keychain cannot read the session (\(status)).")) }
        return try JSONDecoder().decode(SessionToken.self, from: data)
    }
    static func save(_ token: SessionToken) throws {
        let data = try JSONEncoder().encode(token)
        let update = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecItemNotFound {
            var q = query; q[kSecValueData as String] = data
            q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let status = SecItemAdd(q as CFDictionary, nil)
            guard status == errSecSuccess else { throw ProtocolError.invalid(String(localized: "Could not save to the Keychain (\(status)).")) }
        } else if update != errSecSuccess { throw ProtocolError.invalid(String(localized: "Could not update the Keychain (\(update)).")) }
    }
    static func delete() { SecItemDelete(query as CFDictionary) }
}

@MainActor final class CloudAPI {
    nonisolated static let clientID = "99c32114-c124-4aac-881e-adb1550e8cd7"
    nonisolated static let scope = "data:products user:profile user:manage user:certificate mobile:notifications mower:view mower:update mower:activity_log mower:lawn mower:warranty mower:firmware mower:pair mower:unpair mower:map"
    nonisolated static let redirectURI = "https://app.worxlandroid.com/login"
    private let session: URLSession
    private var refreshTask: Task<SessionToken, Error>?
    init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 25; config.timeoutIntervalForResource = 35
        config.httpAdditionalHeaders = ["Accept": "application/json", "User-Agent": "MowerBar/\(AppInfo.version)"]
        session = URLSession(configuration: config)
    }
    func token(force: Bool = false) async throws -> SessionToken {
        if let refreshTask { return try await refreshTask.value }
        guard let token = try SecureSession.load() else { throw ProtocolError.invalid(String(localized: "Connect your Worx account to find your mower.")) }
        if !force && token.expiresAt.timeIntervalSinceNow > 300 { return token }
        let task = Task { @MainActor in
            let fresh = try await self.oauth(["grant_type": "refresh_token", "client_id": Self.clientID,
                "scope": Self.scope, "refresh_token": token.refreshToken])
            try SecureSession.save(fresh); return fresh
        }
        refreshTask = task
        defer { refreshTask = nil }
        return try await task.value
    }
    func exchange(code: String, verifier: String) async throws {
        let token = try await oauth(["grant_type": "authorization_code", "client_id": Self.clientID,
            "redirect_uri": Self.redirectURI, "code": code, "code_verifier": verifier])
        try SecureSession.save(token)
    }
    private func oauth(_ parameters: [String: String]) async throws -> SessionToken {
        var request = URLRequest(url: URL(string: "https://id.worx.com/oauth/token")!)
        request.httpMethod = "POST"; request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: parameters)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw ProtocolError.invalid(String(localized: "The Worx sign-in needs to be renewed (HTTP \(code))."))
        }
        return try SessionToken.parse(data)
    }
    func get(_ path: String, retry: Bool = true) async throws -> Any {
        guard path.hasPrefix("/api/v2/"), !path.contains("..") else { throw ProtocolError.invalid(String(localized: "Invalid read path.")) }
        let token = try await token()
        var request = URLRequest(url: URL(string: "https://api.worxlandroid.com"+path)!)
        request.setValue("Bearer "+token.accessToken, forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ProtocolError.invalid(String(localized: "Invalid Worx response.")) }
        if http.statusCode == 401 && retry {
            // A concurrent request may already have replaced the token while this one was in flight.
            if try SecureSession.load()?.accessToken == token.accessToken { _ = try await self.token(force: true) }
            return try await get(path, retry: false)
        }
        guard http.statusCode == 200 else { throw ProtocolError.invalid(http.statusCode == 429 ? "Worx demande de patienter avant une nouvelle lecture." : "Lecture Worx impossible (HTTP \(http.statusCode)).") }
        return try JSONSerialization.jsonObject(with: data)
    }
    func inventory() async throws -> [Mower] {
        async let items = get("/api/v2/product-items?status=1&gps_status=1&all=1")
        async let catalog = get("/api/v2/products")
        let (a, b) = try await (items, catalog)
        guard let values = a as? [[String: Any]], let products = b as? [[String: Any]] else { throw ProtocolError.invalid(String(localized: "Invalid Worx inventory.")) }
        return try values.map { try Mower.parse($0, products: products) }
    }
    func history(_ mower: Mower) async throws -> [Activity] {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-"))
        guard let id = mower.serial.addingPercentEncoding(withAllowedCharacters: allowed) else { throw ProtocolError.invalid(String(localized: "Invalid device.")) }
        guard let data = try await get("/api/v2/product-items/\(id)/activity-log") as? [[String: Any]] else { throw ProtocolError.invalid(String(localized: "Invalid Worx activity log.")) }
        return data.enumerated().map { Activity.parse($0.element, index: $0.offset) }
    }
}
