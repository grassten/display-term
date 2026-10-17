import UIKit
import SwiftTerm

/// One terminal: a SwiftTerm view bound to one SSH session. The view lives for the whole
/// pane and is moved between the phone and the display as the cable comes and goes.
final class Pane: NSObject {
    enum State: Equatable {
        case idle
        case connecting
        case connected
        case disconnected(String)
        case reconnecting(seconds: Int)

        var text: String {
            switch self {
            case .idle: return "Not connected"
            case .connecting: return "Connecting…"
            case .connected: return "Connected"
            case .disconnected(let why): return why
            case .reconnecting(let s): return "Reconnecting in \(s)s"
            }
        }
    }

    let id: UUID
    let profile: Profile
    /// `tmux new-session -A -s <this>` when the profile keeps shells alive.
    let tmuxSession: String
    let terminalView: TerminalView

    private(set) var cols = 80
    private(set) var rows = 24
    private(set) var title = ""
    private(set) var cwd: String?
    private(set) var state: State = .idle {
        didSet { if state != oldValue { onChange?() } }
    }
    private(set) var authenticatedWith = "–"

    var onChange: (() -> Void)?
    var onBell: (() -> Void)?

    private var connection: SSHConnection?
    private var reconnectAttempt = 0
    private var reconnectTimer: Timer?
    private var closedByUser = false
    private var usingTmux = false
    private var sessionEnded = false
    private var lostWhileSuspended = false
    private var keyInstallAttempted = false

    init(id: UUID = UUID(), profile: Profile, tmuxSession: String) {
        self.id = id
        self.profile = profile
        self.tmuxSession = tmuxSession
        terminalView = TerminalView(frame: CGRect(x: 0, y: 0, width: 600, height: 400))
        super.init()
        terminalView.terminalDelegate = self
        terminalView.allowMouseReporting = true
    }

    deinit {
        reconnectTimer?.invalidate()
    }

    // MARK: Titles

    var displayTitle: String {
        if !title.isEmpty { return title }
        if let cwd, let last = cwd.split(separator: "/").last { return String(last) }
        return profile.name
    }

    /// `user@host — cwd — title`, as iTerm2's per-pane title bar shows it.
    var titleBarText: String {
        var parts = ["\(profile.user)@\(profile.hostDisplay)"]
        if let cwd { parts.append(abbreviated(cwd)) }
        if !title.isEmpty, title != cwd { parts.append(title) }
        return parts.joined(separator: " — ")
    }

    private func abbreviated(_ path: String) -> String {
        let home = "/Users/\(profile.user)"
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }

    // MARK: Connection

    func connect() {
        guard connection == nil else { return }
        reconnectTimer?.invalidate()
        closedByUser = false
        sessionEnded = false
        state = .connecting

        let conn = SSHConnection(profile: profile)
        connection = conn
        conn.onData = { [weak self] bytes in self?.feed(bytes) }
        conn.onStatus = { [weak self] text in self?.note(text) }
        conn.onSessionOpened = { [weak self] usedPassword in
            guard let self else { return }
            authenticatedWith = usedPassword ? "password" : "key"
            onChange?()
            if usedPassword, !keyInstallAttempted {
                keyInstallAttempted = true
                installDeviceKey(on: conn)
            }
        }
        conn.onSessionStarted = { [weak self] in
            guard let self else { return }
            state = .connected
            // The shell is up: make sure it has the terminal's real size.
            conn.resize(cols: cols, rows: rows)
            reconnectAttempt = 0
            lostWhileSuspended = false
        }
        conn.onSessionExit = { [weak self] status in self?.sessionExited(status, on: conn) }
        conn.onClosed = { [weak self] reason in self?.connectionClosed(reason, conn) }

        usingTmux = profile.tmux
        conn.connect(cols: cols, rows: rows, command: usingTmux ? Self.tmuxCommand(session: tmuxSession) : nil)
    }

    /// sshd runs exec requests through the login shell with a minimal PATH, so Homebrew's
    /// tmux is only found via a login shell (or the two usual prefixes).
    static func tmuxCommand(session: String) -> String {
        "exec \"$SHELL\" -lc 'PATH=/opt/homebrew/bin:/usr/local/bin:$PATH exec tmux new-session -A -s \(session) \\; set-option status off'"
    }

    private func sessionExited(_ status: Int, on conn: SSHConnection) {
        if usingTmux, status == 127 {
            usingTmux = false
            note("tmux is not installed on the Mac (brew install tmux); opening a plain shell.")
            conn.startSession(cols: cols, rows: rows, command: nil)
            return
        }
        sessionEnded = true
        note("Session ended (exit \(status)). ⌘⇧R reconnects.")
        conn.close()
    }

    private func connectionClosed(_ reason: SSHCloseReason, _ conn: SSHConnection) {
        guard conn === connection else { return }
        connection = nil
        if closedByUser { state = .disconnected("Closed"); return }
        if sessionEnded { state = .disconnected("Session ended"); return }
        if !reason.shouldRetry {
            note(reason.text)
            state = .disconnected(reason.text)
            return
        }
        if UIApplication.shared.applicationState != .active {
            // Suspended: iOS dropped the socket. Reconnect when we come back, not now.
            lostWhileSuspended = true
            state = .disconnected(reason.text)
            return
        }
        scheduleReconnect(after: reason.text)
    }

    private func scheduleReconnect(after reasonText: String) {
        let delays = [1, 2, 4, 8, 15, 30]
        let delay = delays[min(reconnectAttempt, delays.count - 1)]
        reconnectAttempt += 1
        note("\(reasonText) — reconnecting in \(delay)s")
        state = .reconnecting(seconds: delay)
        reconnectTimer?.invalidate()
        reconnectTimer = Timer.scheduledTimer(withTimeInterval: TimeInterval(delay), repeats: false) { [weak self] _ in
            self?.connect()
        }
    }

    /// Back in the foreground after a suspension that killed the socket.
    func resumeIfNeeded() {
        switch state {
        case .reconnecting: reconnectNow()
        case .disconnected where lostWhileSuspended: reconnectNow()
        default: break
        }
    }

    func reconnectNow() {
        reconnectTimer?.invalidate()
        if let connection {
            closedByUser = true
            connection.onClosed = nil
            connection.close()
            self.connection = nil
        }
        reconnectAttempt = 0
        connect()
    }

    /// Closing a pane ends its shell, as ⌘W does in iTerm2: with tmux, the session is
    /// killed on the Mac before the connection drops, so detached sessions don't pile up.
    func close() {
        closedByUser = true
        reconnectTimer?.invalidate()
        let conn = connection
        connection = nil
        state = .disconnected("Closed")
        guard let conn else { return }
        conn.onClosed = nil
        if usingTmux {
            conn.exec(Self.tmuxKillCommand(session: tmuxSession)) { _, _ in conn.close() }
        } else {
            conn.close()
        }
    }

    static func tmuxKillCommand(session: String) -> String {
        "PATH=/opt/homebrew/bin:/usr/local/bin:$PATH tmux kill-session -t \(session)"
    }

    private func installDeviceKey(on conn: SSHConnection) {
        guard let line = DeviceKey.publicKeyLine() else { return }
        conn.exec(KeyInstaller.command(publicKeyLine: line)) { [weak self] status, output in
            guard let self else { return }
            if status == 0 {
                AppState.shared.statusMessage = "Key installed on \(profile.hostDisplay); next connection needs no password"
            } else {
                AppState.shared.statusMessage = "Could not install key (\(status)): \(output.prefix(80))"
            }
        }
    }

    // MARK: Terminal I/O

    private func feed(_ bytes: [UInt8]) {
        terminalView.feed(byteArray: bytes[...])
    }

    private func note(_ text: String) {
        feed(Array("\r\n\u{1b}[2m[Display Term] \(text)\u{1b}[0m\r\n".utf8))
    }

    func sendText(_ text: String) { terminalView.send(txt: text) }
    func send(_ bytes: [UInt8]) { terminalView.send(bytes) }

    /// iTerm2's Clear Buffer: drop the scrollback and wipe the screen locally.
    func clearBuffer() {
        terminalView.clearScrollback()
        terminalView.feed(text: "\u{1b}[2J\u{1b}[H")
    }

    func resetTerminal() {
        terminalView.feed(text: "\u{1b}c")
    }
}

extension Pane: TerminalViewDelegate {
    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        cols = newCols
        rows = newRows
        connection?.resize(cols: newCols, rows: newRows)
        onChange?()
    }

    func setTerminalTitle(source: TerminalView, title: String) {
        self.title = title
        onChange?()
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        // OSC 7 carries file://host/path.
        if let directory, let url = URL(string: directory), url.scheme == "file" {
            cwd = url.path
        } else {
            cwd = directory
        }
        onChange?()
    }

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        connection?.write(Array(data))
    }

    func scrolled(source: TerminalView, position: Double) {}

    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        guard let url = URL(string: link) else { return }
        UIApplication.shared.open(url)
    }

    func bell(source: TerminalView) { onBell?() }

    func clipboardCopy(source: TerminalView, content: Data) {
        UIPasteboard.general.string = String(decoding: content, as: UTF8.self)
    }

    func clipboardRead(source: TerminalView) -> Data? {
        UIPasteboard.general.string?.data(using: .utf8)
    }

    func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}

enum KeyInstaller {
    /// Appends the device's public key to ~/.ssh/authorized_keys once, with safe modes.
    static func command(publicKeyLine: String) -> String {
        let key = publicKeyLine.replacingOccurrences(of: "'", with: "")
        return "umask 077; mkdir -p ~/.ssh; touch ~/.ssh/authorized_keys; grep -qxF '\(key)' ~/.ssh/authorized_keys || echo '\(key)' >> ~/.ssh/authorized_keys"
    }
}
