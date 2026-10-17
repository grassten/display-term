import Foundation
import CryptoKit

/// known_hosts, as JSON in Application Support, keyed by the profile's host identifier.
final class HostKeyStore {
    struct Entry: Codable, Equatable {
        var line: String
        var fingerprint: String
        var firstSeen: Date
    }

    enum Check {
        case trusted
        case unknown
        case mismatch(previous: Entry)
    }

    static let shared = HostKeyStore()

    private var entries: [String: Entry]
    private let lock = NSLock()
    private static var url: URL { AppFiles.applicationSupport.appendingPathComponent("known_hosts.json") }

    private init() {
        entries = AppFiles.readJSON([String: Entry].self, at: Self.url) ?? [:]
    }

    var all: [(hostID: String, entry: Entry)] {
        lock.lock(); defer { lock.unlock() }
        return entries.map { ($0.key, $0.value) }.sorted { $0.0 < $1.0 }
    }

    func check(hostID: String, line: String) -> Check {
        lock.lock(); defer { lock.unlock() }
        guard let known = entries[hostID] else { return .unknown }
        return known.line == line ? .trusted : .mismatch(previous: known)
    }

    func trust(hostID: String, line: String) {
        lock.lock(); defer { lock.unlock() }
        entries[hostID] = Entry(line: line, fingerprint: Self.fingerprint(openSSHLine: line), firstSeen: Date())
        AppFiles.writeJSON(entries, to: Self.url)
    }

    func forget(hostID: String) {
        lock.lock(); defer { lock.unlock() }
        entries.removeValue(forKey: hostID)
        AppFiles.writeJSON(entries, to: Self.url)
    }

    /// OpenSSH's `SHA256:` fingerprint of a public key line ("ssh-ed25519 AAAA…").
    static func fingerprint(openSSHLine line: String) -> String {
        let parts = line.split(separator: " ")
        guard parts.count >= 2, let blob = Data(base64Encoded: String(parts[1])) else { return "?" }
        let digest = SHA256.hash(data: blob)
        return "SHA256:" + Data(digest).base64EncodedString().trimmingCharacters(in: CharacterSet(charactersIn: "="))
    }
}
