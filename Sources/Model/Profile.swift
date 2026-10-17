import Foundation
import Combine

/// A host to connect to and how. The default profile is the Mac mini found over Bonjour.
struct Profile: Codable, Identifiable, Equatable {
    enum Host: Codable, Equatable {
        /// A Bonjour service name as advertised by Remote Login (e.g. "Mac mini").
        case bonjour(String)
        /// A host name or address and port.
        case address(String, Int)
    }

    var id = UUID()
    var name: String
    var host: Host
    var user: String
    /// Run every pane inside `tmux new-session -A -s <name>` so shells survive disconnects.
    var tmux = true
    var connectOnLaunch = true

    /// Stable identifier for the known-hosts store.
    var hostID: String {
        switch host {
        case .bonjour(let name): return "bonjour:\(name)"
        case .address(let host, let port): return "\(host):\(port)"
        }
    }

    var hostDisplay: String {
        switch host {
        case .bonjour(let name): return name
        case .address(let host, let port): return port == 22 ? host : "\(host):\(port)"
        }
    }
}

final class ProfileStore: ObservableObject {
    private struct File: Codable {
        var profiles: [Profile]
        var defaultID: UUID?
    }

    @Published private(set) var profiles: [Profile] = []
    @Published var defaultID: UUID? { didSet { save() } }

    private static var url: URL { AppFiles.applicationSupport.appendingPathComponent("profiles.json") }

    init() {
        if let file = AppFiles.readJSON(File.self, at: Self.url) {
            profiles = file.profiles
            defaultID = file.defaultID
        }
    }

    var defaultProfile: Profile? {
        profiles.first { $0.id == defaultID } ?? profiles.first
    }

    func profile(id: UUID) -> Profile? { profiles.first { $0.id == id } }

    func upsert(_ profile: Profile) {
        if let i = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[i] = profile
        } else {
            profiles.append(profile)
        }
        if defaultID == nil { defaultID = profile.id }
        save()
    }

    func remove(_ profile: Profile) {
        profiles.removeAll { $0.id == profile.id }
        if defaultID == profile.id { defaultID = profiles.first?.id }
        save()
    }

    private func save() {
        AppFiles.writeJSON(File(profiles: profiles, defaultID: defaultID), to: Self.url)
    }
}
