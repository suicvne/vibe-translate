import Foundation
import Security

/// One generic-password item holding the provider API key. Small enough not to
/// need a dependency, private enough not to belong in UserDefaults.
enum Keychain {
    private static let service = "xyz.ignoresolutions.vibetranslate"
    private static let apiKeyAccount = "provider.apiKey"
    private static let chatGPTAccount = "provider.chatGPT"

    static func apiKey() -> String? {
        guard let data = read(apiKeyAccount) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func setAPIKey(_ value: String) {
        _ = write(value.isEmpty ? nil : Data(value.utf8), account: apiKeyAccount)
    }

    static func chatGPTCredentials() -> Data? { read(chatGPTAccount) }

    @discardableResult
    static func setChatGPTCredentials(_ data: Data?) -> Bool {
        write(data, account: chatGPTAccount)
    }

    private static func read(_ account: String) -> Data? {
        var query = baseQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else { return nil }
        return item as? Data
    }

    private static func write(_ data: Data?, account: String) -> Bool {
        let query = baseQuery(account)

        guard let data else {
            let status = SecItemDelete(query as CFDictionary)
            return status == errSecSuccess || status == errSecItemNotFound
        }

        let update = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var insert = query
            insert[kSecValueData as String] = data
            insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            return SecItemAdd(insert as CFDictionary, nil) == errSecSuccess
        }
        return status == errSecSuccess
    }

    private static func baseQuery(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
