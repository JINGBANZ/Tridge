import Foundation
import Security

/// The OpenAI API key lives only on this device — in the Keychain on real
/// hardware, in UserDefaults on simulators (see below) — never in the repo,
/// logs, or a backend.
enum KeychainStore {
    private static let service = "com.tridge.credentials"
    private static let account = "openai-api-key"

    #if targetEnvironment(simulator)
    // Simulator builds — including the unsigned CI artifact that Appetize.io
    // runs — carry no code-signing entitlements, so every SecItem* call fails
    // with errSecMissingEntitlement (-34018) and a pasted key silently never
    // persists. The simulator keychain adds no real protection over its
    // container anyway, so UserDefaults is the honest equivalent there; real
    // devices use the Keychain path below.
    static var apiKey: String? {
        get {
            guard let key = UserDefaults.standard.string(forKey: account),
                  !key.isEmpty else { return nil }
            return key
        }
        set {
            let trimmed = newValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if trimmed.isEmpty {
                UserDefaults.standard.removeObject(forKey: account)
            } else {
                UserDefaults.standard.set(trimmed, forKey: account)
            }
        }
    }
    #else
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
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            guard status == errSecSuccess,
                  let data = result as? Data,
                  let key = String(data: data, encoding: .utf8),
                  !key.isEmpty else {
                if status != errSecSuccess, status != errSecItemNotFound {
                    AppLog.keychain.error("Key read failed: OSStatus \(status)")
                }
                return nil
            }
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
                let addStatus = SecItemAdd(query as CFDictionary, nil)
                if addStatus != errSecSuccess {
                    AppLog.keychain.error("Key save failed: OSStatus \(addStatus)")
                }
            } else if status != errSecSuccess {
                AppLog.keychain.error("Key update failed: OSStatus \(status)")
            }
        }
    }
    #endif
}
