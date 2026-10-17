import Foundation
import Network
import Combine

/// Finds Macs with Remote Login on the local network (they advertise `_ssh._tcp`).
final class HostBrowser: ObservableObject {
    struct Host: Identifiable, Hashable {
        let name: String
        var id: String { name }
    }

    @Published private(set) var hosts: [Host] = []
    @Published private(set) var status = "Looking for Macs with Remote Login…"
    private var browser: NWBrowser?

    func start() {
        guard browser == nil else { return }
        let browser = NWBrowser(for: .bonjour(type: "_ssh._tcp", domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let hosts = results.compactMap { result -> Host? in
                if case .service(let name, _, _, _) = result.endpoint { return Host(name: name) }
                return nil
            }
            DispatchQueue.main.async {
                self?.hosts = Array(Set(hosts)).sorted { $0.name < $1.name }
                self?.status = hosts.isEmpty ? "No Macs found yet. Remote Login must be on (System Settings › General › Sharing)." : ""
            }
        }
        browser.stateUpdateHandler = { [weak self] state in
            DispatchQueue.main.async {
                switch state {
                case .failed(let error): self?.status = "Discovery failed: \(error.localizedDescription)"
                case .waiting(let error): self?.status = "Waiting for local network access… (\(error.localizedDescription))"
                default: break
                }
            }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    func stop() {
        browser?.cancel()
        browser = nil
    }
}
