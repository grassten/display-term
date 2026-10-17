import Foundation
import Network
import NIOCore
import NIOSSH
import NIOTransportServices

enum SSHCloseReason: Equatable {
    case closed
    case authenticationFailed
    case hostKeyRejected
    case hostKeyMismatch
    case connectFailed(String)
    case lost(String)

    var text: String {
        switch self {
        case .closed: return "Closed"
        case .authenticationFailed: return "Authentication failed"
        case .hostKeyRejected: return "Host key not trusted"
        case .hostKeyMismatch: return "Host key changed — refusing to connect"
        case .connectFailed(let why): return "Could not connect: \(why)"
        case .lost(let why): return why
        }
    }

    /// Network trouble is retried; anything the user has to fix is not.
    var shouldRetry: Bool {
        switch self {
        case .connectFailed, .lost: return true
        default: return false
        }
    }
}

/// One SSH connection carrying one interactive session (plus short exec channels for
/// housekeeping). Callbacks arrive on the main queue.
final class SSHConnection {
    private static let group = NIOTSEventLoopGroup(loopCount: 1)

    let profile: Profile
    var onData: (([UInt8]) -> Void)?
    var onStatus: ((String) -> Void)?
    /// Authenticated and the session channel is open. `true` when the password was used.
    var onSessionOpened: ((Bool) -> Void)?
    /// The PTY was granted; output follows.
    var onSessionStarted: (() -> Void)?
    /// The remote shell or command ended (status, or -1 when the channel just closed).
    var onSessionExit: ((Int) -> Void)?
    var onClosed: ((SSHCloseReason) -> Void)?

    private var channel: Channel?
    private var session: Channel?
    private var handler: NIOSSHHandler?
    private var userClosed = false
    private var reported = false
    private var connectFailure: String?
    private var lastError: String?
    private let auth: ClientAuthDelegate
    private let hostKeys: HostKeyValidator
    private var initialRequest: (cols: Int, rows: Int, command: String?) = (80, 24, nil)

    init(profile: Profile) {
        self.profile = profile
        let p = profile
        auth = ClientAuthDelegate(username: profile.user, key: DeviceKey.loadOrCreate()) { completion in
            PromptCenter.shared.askPassword(for: p, completion: completion)
        }
        hostKeys = HostKeyValidator(hostID: profile.hostID, hostName: profile.hostDisplay)
    }

    // MARK: Connect

    func connect(cols: Int, rows: Int, command: String?) {
        initialRequest = (cols, rows, command)
        let config = SSHClientConfiguration(userAuthDelegate: auth, serverAuthDelegate: hostKeys)
        let bootstrap = NIOTSConnectionBootstrap(group: Self.group)
            .connectTimeout(.seconds(15))
            .channelInitializer { [weak self] channel in
                channel.pipeline.addHandlers([
                    NIOSSHHandler(role: .client(config), allocator: channel.allocator, inboundChildChannelInitializer: nil),
                    ErrorCatcher { error in self?.lastError = Self.describe(error) },
                ])
            }
        status("Connecting to \(profile.hostDisplay)…")
        let future: EventLoopFuture<Channel>
        switch profile.host {
        case .bonjour(let name):
            future = bootstrap.connect(endpoint: .service(name: name, type: "_ssh._tcp", domain: "local.", interface: nil))
        case .address(let host, let port):
            future = bootstrap.connect(host: host, port: port)
        }
        future.whenComplete { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                self.connectFailure = Self.describe(error)
                self.finish()
            case .success(let channel):
                self.channel = channel
                channel.closeFuture.whenComplete { [weak self] _ in self?.finish() }
                channel.pipeline.handler(type: NIOSSHHandler.self).whenSuccess { [weak self] handler in
                    guard let self else { return }
                    self.handler = handler
                    let r = self.initialRequest
                    self.openSession(cols: r.cols, rows: r.rows, command: r.command, first: true)
                }
            }
        }
    }

    /// Open a (new) session channel with a PTY and a shell or command. Used once at connect
    /// and again when a command exits and a plain shell should take its place.
    func startSession(cols: Int, rows: Int, command: String?) {
        openSession(cols: cols, rows: rows, command: command, first: false)
    }

    private func openSession(cols: Int, rows: Int, command: String?, first: Bool) {
        guard let handler, let channel else { return }
        let promise = channel.eventLoop.makePromise(of: Channel.self)
        handler.createChannel(promise, channelType: .session) { [weak self] child, _ in
            let sessionHandler = SessionHandler(
                onData: { bytes in self?.main { self?.onData?(bytes) } },
                onRequestResult: { ok in
                    self?.main {
                        guard let self else { return }
                        if ok { self.onSessionStarted?() } else { self.status("The server refused the terminal request") }
                    }
                },
                onEnded: { [weak self] status in
                    guard let self, self.channel?.isActive == true else { return }
                    self.main { self.onSessionExit?(status ?? -1) }
                })
            return child.pipeline.addHandler(sessionHandler)
        }
        promise.futureResult.whenComplete { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let child):
                self.session = child
                child.triggerUserOutboundEvent(
                    SSHChannelRequestEvent.PseudoTerminalRequest(
                        wantReply: true, term: "xterm-256color",
                        terminalCharacterWidth: cols, terminalRowHeight: rows,
                        terminalPixelWidth: 0, terminalPixelHeight: 0,
                        terminalModes: SSHTerminalModes([:])),
                    promise: nil)
                if let command {
                    child.triggerUserOutboundEvent(SSHChannelRequestEvent.ExecRequest(command: command, wantReply: true), promise: nil)
                } else {
                    child.triggerUserOutboundEvent(SSHChannelRequestEvent.ShellRequest(wantReply: true), promise: nil)
                }
                if first {
                    let usedPassword = self.auth.usedPassword
                    self.main { self.onSessionOpened?(usedPassword) }
                }
            case .failure(let error):
                self.lastError = Self.describe(error)
                channel.close(promise: nil)
            }
        }
    }

    // MARK: I/O

    func write(_ bytes: [UInt8]) {
        guard let session, !bytes.isEmpty else { return }
        session.eventLoop.execute {
            session.writeAndFlush(ByteBuffer(bytes: bytes), promise: nil)
        }
    }

    func resize(cols: Int, rows: Int) {
        guard let session else { return }
        session.eventLoop.execute {
            session.triggerUserOutboundEvent(
                SSHChannelRequestEvent.WindowChangeRequest(terminalCharacterWidth: cols, terminalRowHeight: rows,
                                                           terminalPixelWidth: 0, terminalPixelHeight: 0),
                promise: nil)
        }
    }

    /// Run one command on a separate channel and collect its output.
    func exec(_ command: String, completion: @escaping (Int, String) -> Void) {
        guard let handler, let channel else { completion(-1, "not connected"); return }
        let collector = ExecCollector(completion: completion)
        let promise = channel.eventLoop.makePromise(of: Channel.self)
        handler.createChannel(promise, channelType: .session) { child, _ in
            child.pipeline.addHandler(SessionHandler(
                onData: { collector.output.append(contentsOf: $0) },
                onRequestResult: { _ in },
                onEnded: { status in collector.finish(status ?? -1) }))
        }
        promise.futureResult.whenComplete { result in
            switch result {
            case .success(let child):
                child.triggerUserOutboundEvent(SSHChannelRequestEvent.ExecRequest(command: command, wantReply: true), promise: nil)
            case .failure(let error):
                collector.output = Array(Self.describe(error).utf8)
                collector.finish(-1)
            }
        }
    }

    func close() {
        userClosed = true
        channel?.close(promise: nil)
        if channel == nil { finish() }
    }

    // MARK: Teardown

    private func finish() {
        guard !reported else { return }
        reported = true
        let reason: SSHCloseReason
        if userClosed {
            reason = .closed
        } else if hostKeys.mismatch {
            reason = .hostKeyMismatch
        } else if hostKeys.rejected {
            reason = .hostKeyRejected
        } else if auth.gaveUp {
            reason = .authenticationFailed
        } else if let connectFailure {
            reason = .connectFailed(connectFailure)
        } else {
            reason = .lost(lastError ?? "Connection closed")
        }
        main { self.onClosed?(reason) }
    }

    private func status(_ text: String) { main { self.onStatus?(text) } }

    private func main(_ work: @escaping () -> Void) {
        if Thread.isMainThread { work() } else { DispatchQueue.main.async(execute: work) }
    }

    static func describe(_ error: Error) -> String {
        if let nw = error as? NWError { return nw.debugDescription }
        let text = String(describing: error)
        return text.count > 120 ? String(text.prefix(120)) + "…" : text
    }
}

private final class ExecCollector {
    var output: [UInt8] = []
    private var done = false
    private let completion: (Int, String) -> Void

    init(completion: @escaping (Int, String) -> Void) { self.completion = completion }

    func finish(_ status: Int) {
        guard !done else { return }
        done = true
        let text = String(decoding: output, as: UTF8.self)
        DispatchQueue.main.async { self.completion(status, text) }
    }
}

/// Lives in a session child channel: unwraps incoming channel data to bytes, wraps outgoing
/// bytes, and reports request replies and the exit status.
final class SessionHandler: ChannelDuplexHandler {
    typealias InboundIn = SSHChannelData
    typealias InboundOut = Never
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = SSHChannelData

    private let onData: ([UInt8]) -> Void
    private let onRequestResult: (Bool) -> Void
    private let onEnded: (Int?) -> Void
    private var exitStatus: Int?
    private var repliedOnce = false

    init(onData: @escaping ([UInt8]) -> Void, onRequestResult: @escaping (Bool) -> Void, onEnded: @escaping (Int?) -> Void) {
        self.onData = onData
        self.onRequestResult = onRequestResult
        self.onEnded = onEnded
    }

    func handlerAdded(context: ChannelHandlerContext) {
        _ = context.channel.setOption(ChannelOptions.allowRemoteHalfClosure, value: true)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let channelData = unwrapInboundIn(data)
        guard case .byteBuffer(var buffer) = channelData.data,
              let bytes = buffer.readBytes(length: buffer.readableBytes), !bytes.isEmpty else { return }
        onData(bytes)
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        switch event {
        case let status as SSHChannelRequestEvent.ExitStatus:
            exitStatus = status.exitStatus
        case is ChannelSuccessEvent:
            if !repliedOnce { repliedOnce = true; onRequestResult(true) }
        case is ChannelFailureEvent:
            onRequestResult(false)
        default:
            context.fireUserInboundEventTriggered(event)
        }
    }

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let buffer = unwrapOutboundIn(data)
        context.write(wrapOutboundOut(SSHChannelData(type: .channel, data: .byteBuffer(buffer))), promise: promise)
    }

    func channelInactive(context: ChannelHandlerContext) {
        onEnded(exitStatus)
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.close(promise: nil)
    }
}

/// Records the error that took the connection down, then closes it.
final class ErrorCatcher: ChannelInboundHandler {
    typealias InboundIn = Any
    private let onError: (Error) -> Void

    init(onError: @escaping (Error) -> Void) { self.onError = onError }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        onError(error)
        context.close(promise: nil)
    }
}
