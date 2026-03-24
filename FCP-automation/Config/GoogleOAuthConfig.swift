import Foundation
import Security

/// Google OAuth 2.0 認証情報のKeychain管理
enum GoogleOAuthConfig {
    private static let serviceName = "com.SerenoSystem.FCP-automation"
    private static let clientIDAccount = "google-oauth-client-id"
    private static let refreshTokenAccount = "google-oauth-refresh-token"
    private static let accessTokenAccount = "google-oauth-access-token"

    // MARK: - Client ID

    static func saveClientID(_ id: String) {
        saveToKeychain(account: clientIDAccount, value: id)
    }

    static func loadClientID() -> String? {
        loadFromKeychain(account: clientIDAccount)
    }

    // MARK: - Tokens

    static func saveTokens(accessToken: String, refreshToken: String?, expiresIn: Int) {
        // Access token + 有効期限をJSON形式で保存
        let expiresAt = Date().timeIntervalSince1970 + Double(expiresIn)
        let dict: [String: Any] = ["token": accessToken, "expires_at": expiresAt]
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              let tokenJSON = String(data: data, encoding: .utf8) else { return }
        saveToKeychain(account: accessTokenAccount, value: tokenJSON)

        if let refresh = refreshToken {
            saveToKeychain(account: refreshTokenAccount, value: refresh)
        }
    }

    static func loadAccessToken() -> String? {
        guard let json = loadFromKeychain(account: accessTokenAccount),
              let data = json.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = dict["token"] as? String else {
            return nil
        }
        return token
    }

    static func isTokenExpired() -> Bool {
        guard let json = loadFromKeychain(account: accessTokenAccount),
              let data = json.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let expiresAt = dict["expires_at"] as? Double else {
            return true
        }
        // 5分前に期限切れとみなす（余裕を持つ）
        return Date().timeIntervalSince1970 > expiresAt - 300
    }

    static func loadRefreshToken() -> String? {
        loadFromKeychain(account: refreshTokenAccount)
    }

    static func deleteAllTokens() {
        deleteFromKeychain(account: accessTokenAccount)
        deleteFromKeychain(account: refreshTokenAccount)
    }

    static func deleteAll() {
        deleteFromKeychain(account: clientIDAccount)
        deleteAllTokens()
    }

    static var isConfigured: Bool {
        loadClientID() != nil
    }

    static var hasValidTokens: Bool {
        loadAccessToken() != nil && loadRefreshToken() != nil
    }

    // MARK: - Keychain Helpers

    private static func saveToKeychain(account: String, value: String) {
        guard let data = value.data(using: .utf8) else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
        var addQuery = query
        addQuery[kSecValueData as String] = data
        SecItemAdd(addQuery as CFDictionary, nil)
    }

    private static func loadFromKeychain(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else {
            return nil
        }
        return value
    }

    private static func deleteFromKeychain(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}
