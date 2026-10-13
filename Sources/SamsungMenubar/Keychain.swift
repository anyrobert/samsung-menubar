import Foundation
import Security

enum PairingKey {
    static func query(_ host: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "br.local.SamsungRemote", kSecAttrAccount as String: host]
    }
    static func read(_ host: String) -> String? {
        var q = query(host); q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
    static func save(_ key: String, host: String) throws {
        let q = query(host), data = Data(key.utf8)
        let status = SecItemUpdate(q as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var insert = q; insert[kSecValueData as String] = data
            insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            guard SecItemAdd(insert as CFDictionary, nil) == errSecSuccess else { throw RemoteError.message("Could not save the TV token in Keychain.") }
        } else if status != errSecSuccess { throw RemoteError.message("Keychain refused the TV token (\(status)).") }
    }
    static func delete(_ host: String) throws {
        let status = SecItemDelete(query(host) as CFDictionary)
        var failures: [String] = []
        if status != errSecSuccess && status != errSecItemNotFound {
            failures.append("Keychain refused to remove the TV token (\(status)).")
        }
        // Attempt both removals even if one fails, then report any remaining item.
        do { try TVCertificatePin.delete(host) }
        catch { failures.append(error.localizedDescription) }
        if !failures.isEmpty { throw RemoteError.message(failures.joined(separator: " ")) }
    }
}

// Pins are private to this Mac and TV, just like the TV access token. They are
// never bundled with the app or written into a diagnostic/exported report.
enum TVCertificatePin {
    private static func query(_ host: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "br.local.SamsungRemote.Certificate",
         kSecAttrAccount as String: host]
    }
    static func read(_ host: String) -> String? {
        var q = query(host)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data, let pin = String(data: data, encoding: .utf8),
              pin.count == 64, pin.allSatisfy({ $0.isHexDigit }) else { return nil }
        return pin.lowercased()
    }
    static func save(_ fingerprint: String, host: String) throws {
        let q = query(host), data = Data(fingerprint.utf8)
        let status = SecItemUpdate(q as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var insert = q
            insert[kSecValueData as String] = data
            insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            guard SecItemAdd(insert as CFDictionary, nil) == errSecSuccess else {
                throw RemoteError.message("Could not save the TV certificate in Keychain.")
            }
        } else if status != errSecSuccess {
            throw RemoteError.message("Keychain refused the TV certificate (\(status)).")
        }
    }
    static func delete(_ host: String) throws {
        let status = SecItemDelete(query(host) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw RemoteError.message("Keychain refused to remove the TV certificate (\(status)).")
        }
    }
}
