import UIKit

/// Questions the SSH layer needs answered on the phone: passwords and host-key trust.
/// Prompts queue behind one another and wait for a presenter to exist.
final class PromptCenter {
    static let shared = PromptCenter()

    weak var presenter: UIViewController? { didSet { pump() } }
    private var queue: [(UIViewController, @escaping () -> Void) -> Void] = []
    private var busy = false

    func askPassword(for profile: Profile, completion: @escaping (String?) -> Void) {
        enqueue { presenter, done in
            let alert = UIAlertController(title: "Password for \(profile.user)@\(profile.hostDisplay)",
                                          message: "Used once; the app installs its own key so you will not be asked again.",
                                          preferredStyle: .alert)
            alert.addTextField { field in
                field.isSecureTextEntry = true
                field.placeholder = "macOS password"
                field.textContentType = .password
            }
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in completion(nil); done() })
            alert.addAction(UIAlertAction(title: "Connect", style: .default) { _ in
                completion(alert.textFields?.first?.text)
                done()
            })
            presenter.present(alert, animated: true)
        }
    }

    func confirmHostKey(host: String, keyType: String, fingerprint: String, completion: @escaping (Bool) -> Void) {
        enqueue { presenter, done in
            let alert = UIAlertController(
                title: "First connection to \(host)",
                message: "\(keyType)\n\(fingerprint)\n\nCompare with `ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub` on the Mac.",
                preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in completion(false); done() })
            alert.addAction(UIAlertAction(title: "Trust", style: .default) { _ in completion(true); done() })
            presenter.present(alert, animated: true)
        }
    }

    func show(_ title: String, _ message: String) {
        enqueue { presenter, done in
            let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in done() })
            presenter.present(alert, animated: true)
        }
    }

    private func enqueue(_ job: @escaping (UIViewController, @escaping () -> Void) -> Void) {
        queue.append(job)
        pump()
    }

    private func pump() {
        guard !busy, let presenter, presenter.presentedViewController == nil, !queue.isEmpty else { return }
        busy = true
        let job = queue.removeFirst()
        job(presenter) { [weak self] in
            self?.busy = false
            DispatchQueue.main.async { self?.pump() }
        }
    }
}
