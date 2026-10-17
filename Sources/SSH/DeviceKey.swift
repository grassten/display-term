import Foundation
import CryptoKit
import Security

/// The phone's own ed25519 key, generated once and kept in the Keychain. Its public half is
/// what gets appended to ~/.ssh/authorized_keys on the Mac.
enum DeviceKey {
    private static let service = "com.grassten.displaybrowser.ssh"
    private static let account = "device-ed25519"

    static func load() -> Curve25519.Signing.PrivateKey? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return try? Curve25519.Signing.PrivateKey(rawRepresentation: data)
    }

    @discardableResult
    static func loadOrCreate() -> Curve25519.Signing.PrivateKey? {
        if let key = load() { return key }
        let key = Curve25519.Signing.PrivateKey()
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: key.rawRepresentation,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else {
            NSLog("[DeviceKey] keychain add failed: \(status)")
            return nil
        }
        return key
    }

    static func publicKeyLine(comment: String = "display-term") -> String? {
        guard let key = loadOrCreate() else { return nil }
        return openSSH(publicKey: key.publicKey, comment: comment)
    }

    /// "ssh-ed25519 <base64(string type, string key)> comment"
    static func openSSH(publicKey: Curve25519.Signing.PublicKey, comment: String) -> String {
        var blob = Data()
        func append(_ field: Data) {
            var length = UInt32(field.count).bigEndian
            blob.append(Data(bytes: &length, count: 4))
            blob.append(field)
        }
        append(Data("ssh-ed25519".utf8))
        append(publicKey.rawRepresentation)
        return "ssh-ed25519 \(blob.base64EncodedString()) \(comment)"
    }

    static var fingerprint: String? {
        publicKeyLine().map { HostKeyStore.fingerprint(openSSHLine: $0) }
    }
}
