import Foundation
import Security

/// TMDB is the first provider that needs a secret, so this is the app's
/// first Keychain use. A direct `SecItem*` wrapper rather than a dependency,
/// per `DECISIONS.md`'s "no third-party dependencies" — the whole surface
/// this app needs is four calls.
public struct TMDBKeyStore: Sendable {
    private let service: String

    public init(service: String = "omnitag.tmdb") {
        self.service = service
    }

    private var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
    }

    public func key() -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func save(key: String) {
        let data = Data(key.utf8)
        if SecItemCopyMatching(baseQuery as CFDictionary, nil) == errSecSuccess {
            SecItemUpdate(baseQuery as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        } else {
            var attributes = baseQuery
            attributes[kSecValueData as String] = data
            SecItemAdd(attributes as CFDictionary, nil)
        }
    }

    public func delete() {
        SecItemDelete(baseQuery as CFDictionary)
    }
}
