import Foundation
import CryptoKit
import NIOCore
import NIOSSH

/// Offers the device key first, then asks the phone for the password (up to three tries).
final class ClientAuthDelegate: NIOSSHClientUserAuthenticationDelegate {
    private let username: String
    private let key: Curve25519.Signing.PrivateKey?
    private let askPassword: (@escaping (String?) -> Void) -> Void
    private var triedKey = false
    private var passwordAttempts = 0
    private(set) var usedPassword = false
    private(set) var gaveUp = false

    init(username: String, key: Curve25519.Signing.PrivateKey?, askPassword: @escaping (@escaping (String?) -> Void) -> Void) {
        self.username = username
        self.key = key
        self.askPassword = askPassword
    }

    func nextAuthenticationType(availableMethods: NIOSSHAvailableUserAuthenticationMethods,
                                nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>) {
        if let key, !triedKey, availableMethods.contains(.publicKey) {
            triedKey = true
            let offer = NIOSSHUserAuthenticationOffer(
                username: username, serviceName: "",
                offer: .privateKey(.init(privateKey: NIOSSHPrivateKey(ed25519Key: key))))
            nextChallengePromise.succeed(offer)
            return
        }
        guard availableMethods.contains(.password), passwordAttempts < 3 else {
            gaveUp = true
            nextChallengePromise.succeed(nil)
            return
        }
        passwordAttempts += 1
        let username = self.username
        DispatchQueue.main.async {
            self.askPassword { [weak self] password in
                guard let password, !password.isEmpty else {
                    self?.gaveUp = true
                    nextChallengePromise.succeed(nil)
                    return
                }
                self?.usedPassword = true
                nextChallengePromise.succeed(NIOSSHUserAuthenticationOffer(
                    username: username, serviceName: "", offer: .password(.init(password: password))))
            }
        }
    }
}

struct SSHHostKeyError: Error {
    let message: String
}

/// Trust on first use: a new host's fingerprint is shown on the phone; a changed one refuses.
final class HostKeyValidator: NIOSSHClientServerAuthenticationDelegate {
    private let hostID: String
    private let hostName: String
    private(set) var rejected = false
    private(set) var mismatch = false

    init(hostID: String, hostName: String) {
        self.hostID = hostID
        self.hostName = hostName
    }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        let line = String(openSSHPublicKey: hostKey)
        let fingerprint = HostKeyStore.fingerprint(openSSHLine: line)
        let type = line.split(separator: " ").first.map(String.init) ?? "key"
        switch HostKeyStore.shared.check(hostID: hostID, line: line) {
        case .trusted:
            validationCompletePromise.succeed(())
        case .mismatch:
            mismatch = true
            validationCompletePromise.fail(SSHHostKeyError(message: "host key for \(hostName) changed"))
        case .unknown:
            let hostID = self.hostID
            let hostName = self.hostName
            DispatchQueue.main.async {
                PromptCenter.shared.confirmHostKey(host: hostName, keyType: type, fingerprint: fingerprint) { [weak self] trusted in
                    if trusted {
                        HostKeyStore.shared.trust(hostID: hostID, line: line)
                        validationCompletePromise.succeed(())
                    } else {
                        self?.rejected = true
                        validationCompletePromise.fail(SSHHostKeyError(message: "host key rejected"))
                    }
                }
            }
        }
    }
}
