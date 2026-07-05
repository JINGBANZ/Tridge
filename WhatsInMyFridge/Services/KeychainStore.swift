import Foundation
import Security

/// The OpenAI API key lives only here — in the device Keychain — never in
/// the repo, UserDefaults, or logs.
enum KeychainStore {
    private static let service = "com.whatsinmyfridge.credentials"
    private static let account = "openai-api-key"

    private static var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    static var apiKey: String? {
        get {
            var query = baseQuery
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            var result: AnyObject?
            guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
                  let data = result as? Data,
                  let key = String(data: data, encoding: .utf8),
                  !key.isEmpty else { return nil }
            return key
        }
        set {
            let trimmed = newValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !trimmed.isEmpty else {
                SecItemDelete(baseQuery as CFDictionary)
                return
            }
            let data = Data(trimmed.utf8)
            let status = SecItemUpdate(baseQuery as CFDictionary,
                                       [kSecValueData as String: data] as CFDictionary)
            if status == errSecItemNotFound {
                var query = baseQuery
                query[kSecValueData as String] = data
                query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
                SecItemAdd(query as CFDictionary, nil)
            }
        }
    }
}
