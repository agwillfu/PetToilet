import Foundation
import Security

/// Adafruit IO 憑證。
///
/// AIO Key 等同於帳號密碼 —— 拿到它就能讀寫這個帳號底下所有的 feed，
/// 也就是能任意啟動水泵。所以存在 Keychain 而不是 UserDefaults。
struct Credentials: Sendable, Equatable {
    var username: String
    var key: String

    var isComplete: Bool {
        !username.trimmingCharacters(in: .whitespaces).isEmpty &&
        !key.trimmingCharacters(in: .whitespaces).isEmpty
    }
}

enum CredentialStore {
    private static let service = "com.agwill.PetToilet.adafruit"
    private static let account = "aio"
    private static let usernameKey = "PetToilet.aioUsername"

    /// 使用者名稱不是機密（它出現在每一個 MQTT topic 裡），放 UserDefaults 就好。
    /// 只有 Key 需要 Keychain 保護。
    static func load() -> Credentials {
        #if DEBUG
        // 開發用：讓模擬器不必每次手動輸入帳密。
        //   SIMCTL_CHILD_AIO_USER=… SIMCTL_CHILD_AIO_KEY=… xcrun simctl launch booted …
        // 只在 DEBUG build 生效，Release 版不含這段程式碼。
        let env = ProcessInfo.processInfo.environment
        if let u = env["AIO_USER"], let k = env["AIO_KEY"], !u.isEmpty, !k.isEmpty {
            return Credentials(username: u, key: k)
        }
        #endif
        let username = UserDefaults.standard.string(forKey: usernameKey) ?? ""
        return Credentials(username: username, key: readKey() ?? "")
    }

    static func save(_ c: Credentials) {
        UserDefaults.standard.set(c.username, forKey: usernameKey)
        writeKey(c.key)
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: usernameKey)
        var q = baseQuery()
        q[kSecClass as String] = kSecClassGenericPassword
        SecItemDelete(q as CFDictionary)
    }

    // MARK: - Keychain

    private static func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private static func readKey() -> String? {
        var q = baseQuery()
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func writeKey(_ value: String) {
        let data = Data(value.utf8)
        let query = baseQuery()

        // 先試更新，不存在才新增 —— SecItemAdd 對已存在的項目會回 errSecDuplicateItem
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            // 只在本機解鎖後可讀，且不同步到 iCloud Keychain
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add.merge(attributes) { a, _ in a }
            SecItemAdd(add as CFDictionary, nil)
        }
    }
}
