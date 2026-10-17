import Foundation
import Network
import Combine

/// Finds Macs with Remote Login on the local network (they advertise `_ssh._tcp`).
///
/// The first browse of an app's life is interrupted by iOS's Local Network permission
/// prompt and dies with `DefunctConnection` (-65569); the browser is recreated until it
/// works, so answering the prompt is enough.
final class HostBrowser: ObservableObject {
    struct Host: Identifiable, Hashable {
        let name: String
        var id: String { name }
    }

    @Published private(set) var hosts: [Host] = []
    @Published private(set) var status = "Looking for Macs with Remote Login…"
    private var browser: NWBrowser?
    private var retries = 0
    private var retryWork: DispatchWorkItem?

    func start() {
        guard browser == nil else { return }
        retryWork?.cancel()
        let browser = NWBrowser(for: .bonjour(type: "_ssh._tcp", domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let hosts = results.compactMap { result -> Host? in
                if case .service(let name, _, _, _) = result.endpoint { return Host(name: name) }
                return nil
            }
            DispatchQueue.main.async {
                self?.retries = 0
                self?.hosts = Array(Set(hosts)).sorted { $0.name < $1.name }
                self?.status = hosts.isEmpty ? "No Macs found yet. Remote Login must be on (System Settings › General › Sharing)." : ""
            }
        }
        browser.stateUpdateHandler = { [weak self] state in
            DispatchQueue.main.async {
                guard let self else { return }
                switch state {
                case .ready:
                    if self.hosts.isEmpty { self.status = "Looking for Macs with Remote Login…" }
                case .failed(let error):
                    NSLog("[Bonjour] browse failed: \(error)")
                    self.status = "Discovery failed (\(error.localizedDescription)); retrying…"
                    self.restartAfterFailure()
                case .waiting(let error):
                    self.status = "Waiting for Local Network access (\(error.localizedDescription)). Allow it in Settings › Privacy › Local Network if you declined."
                case .cancelled:
                    break
                default:
                    break
                }
            }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    func stop() {
        retryWork?.cancel()
        browser?.cancel()
        browser = nil
    }

    /// Fresh browser; used after a failure and when the app returns to the foreground.
    func restart() {
        stop()
        start()
    }

    private func restartAfterFailure() {
        browser?.cancel()
        browser = nil
        guard retries < 10 else {
            status = "Discovery keeps failing. Check Settings › Privacy & Security › Local Network › Display Term, or turn Bonjour off and type the Mac's address."
            return
        }
        retries += 1
        let work = DispatchWorkItem { [weak self] in self?.start() }
        retryWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(min(retries, 5)), execute: work)
    }
}
