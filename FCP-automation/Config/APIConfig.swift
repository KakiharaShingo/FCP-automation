import Foundation
import Security

enum APIConfig {
    private static let serviceName = "com.SerenoSystem.FCP-automation"
    private static let claudeAPIKeyAccount = "claude-api-key"

    // MARK: - Claude API Key

    private static let apiKeyDefaultsKey = "claude-api-key-fallback"

    static func saveClaudeAPIKey(_ key: String) {
        guard let data = key.data(using: .utf8) else { return }

        // Keychain に保存を試みる
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: claudeAPIKeyAccount
        ]
        SecItemDelete(query as CFDictionary)

        var addQuery = query
        addQuery[kSecValueData as String] = data
        let status = SecItemAdd(addQuery as CFDictionary, nil)

        if status != errSecSuccess {
            // Keychain 失敗時は UserDefaults にフォールバック
            print("[APIConfig] Keychain保存失敗 (status: \(status))、UserDefaultsにフォールバック")
            UserDefaults.standard.set(key, forKey: apiKeyDefaultsKey)
        } else {
            // Keychain 成功時は UserDefaults のフォールバックを削除
            UserDefaults.standard.removeObject(forKey: apiKeyDefaultsKey)
        }
    }

    static func loadClaudeAPIKey() -> String? {
        // まず Keychain から読み込み
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: claudeAPIKeyAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecSuccess,
           let data = result as? Data,
           let key = String(data: data, encoding: .utf8) {
            return key
        }

        // Keychain 失敗時は UserDefaults から読み込み
        if let fallback = UserDefaults.standard.string(forKey: apiKeyDefaultsKey), !fallback.isEmpty {
            return fallback
        }

        return nil
    }

    static func deleteClaudeAPIKey() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: claudeAPIKeyAccount
        ]
        SecItemDelete(query as CFDictionary)
        UserDefaults.standard.removeObject(forKey: apiKeyDefaultsKey)
    }

    // MARK: - Whisper Model Path

    static var defaultModelDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("FCP-automation/Models")
    }

    static func ensureModelDirectoryExists() throws {
        let dir = defaultModelDirectory
        if !FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }
}
