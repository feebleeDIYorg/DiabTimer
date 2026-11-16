import Foundation
import Security

/// Zugangsdaten zum Nightscout-Server.
struct ServerCredentials: Codable, Equatable, Sendable {
    var url: URL
    var token: String
}

/// Speichert die Zugangsdaten im Keychain. Die App Group dient als Access Group, damit die
/// Widget-Extension sie mitnutzen kann. Nicht über den iCloud-Schlüsselbund synchronisiert.
enum CredentialStore {
    private static let service = "DiabTimer.nightscout"
    private static let account = "default"

    static func load() -> ServerCredentials? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        var status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecMissingEntitlement {
            query.removeValue(forKey: kSecAttrAccessGroup as String)
            status = SecItemCopyMatching(query as CFDictionary, &result)
        }
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(ServerCredentials.self, from: data)
    }

    static func save(_ credentials: ServerCredentials) throws {
        let data = try JSONEncoder().encode(credentials)
        delete()
        var attributes = baseQuery()
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        var status = SecItemAdd(attributes as CFDictionary, nil)
        if status == errSecMissingEntitlement {
            // z. B. im Simulator ohne Signierung: ohne Access Group speichern.
            attributes.removeValue(forKey: kSecAttrAccessGroup as String)
            status = SecItemAdd(attributes as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }

    static func delete() {
        var query = baseQuery()
        SecItemDelete(query as CFDictionary)
        query.removeValue(forKey: kSecAttrAccessGroup as String)
        SecItemDelete(query as CFDictionary)
    }

    private static func baseQuery() -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false,
        ]
        if let group = AppConfiguration.appGroupIdentifier {
            query[kSecAttrAccessGroup as String] = group
        }
        return query
    }
}
