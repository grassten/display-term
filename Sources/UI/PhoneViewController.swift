import UIKit
import Combine

/// The phone-side controller. This is where iOS delivers hardware keyboard input, so every
/// shortcut, normal-mode key and insert-mode keystroke is handled here and applied to the
/// shared BrowserModel, which the display scene renders.
final class PhoneViewController: UIViewController, UITextFieldDelegate {
    private let model = BrowserModel.shared
    private var cancellable: AnyCancellable?
    private var renderScheduled = false

    private let statusLabel = UILabel()
    private let urlField = UITextField()
    private let relayField = RelayTextField()
    private let tabsLabel = UILabel()
    private let helpLabel = UILabel()
    private let webContainer = UIView()

    private var displayRegistration: Any?
    private var pendingG = false
    private var pendingGTime: TimeInterval = 0

    override var canBecomeFirstResponder: Bool { true }

    // MARK: Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        model.presenter = self
        buildLayout()
        registerDisplayAccessoryIfNeeded()

        cancellable = model.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.scheduleRender() }
        render()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        becomeFirstResponder()
    }

    /// iOS 27 no longer offers the external-display scene from Info.plist alone; the app
    /// must register a scene accessory. Earlier releases keep using the manifest.
    private func registerDisplayAccessoryIfNeeded() {
        if #available(iOS 27.0, *) {
            let configuration = UISceneConfiguration(name: "Display", sessionRole: .windowExternalDisplayNonInteractive)
            configuration.delegateClass = DisplaySceneDelegate.self
            let accessory = UISceneAccessory.externalNonInteractive(sceneConfiguration: configuration)
            displayRegistration = registerSceneAccessory(accessory)
        }
    }

    private func buildLayout() {
        statusLabel.font = .monospacedSystemFont(ofSize: 13, weight: .semibold)
        statusLabel.numberOfLines = 2

        urlField.borderStyle = .roundedRect
        urlField.placeholder = "Search or enter URL (⌘L)"
        urlField.keyboardType = .URL
        urlField.autocapitalizationType = .none
        urlField.autocorrectionType = .no
        urlField.returnKeyType = .go
        urlField.clearButtonMode = .whileEditing
        urlField.delegate = self

        relayField.borderStyle = .roundedRect
        relayField.placeholder = "Typing goes to the page (Esc to stop)"
        relayField.delegate = self
        relayField.onInsert = { [weak self] text in self?.model.insertText(text) }
        relayField.onDelete = { [weak self] in self?.model.deleteBackward() }
        relayField.onEnter = { [weak self] shift in self?.model.pressEnter(shift: shift) }
        relayField.onArrow = { [weak self] dir in self?.model.moveCaret(dir) }
        relayField.onTab = { [weak self] reverse in self?.model.focusNext(reverse: reverse) }

        tabsLabel.font = .systemFont(ofSize: 13)
        tabsLabel.numberOfLines = 0
        helpLabel.font = .systemFont(ofSize: 12)
        helpLabel.textColor = .secondaryLabel
        helpLabel.numberOfLines = 0

        let stack = UIStackView(arrangedSubviews: [statusLabel, urlField, relayField, tabsLabel, helpLabel, webContainer])
        stack.axis = .vertical
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            stack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -12),
            stack.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
        ])
        webContainer.setContentHuggingPriority(.defaultLow, for: .vertical)
    }

    // MARK: Rendering

    private func scheduleRender() {
        guard !renderScheduled else { return }
        renderScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.renderScheduled = false
            self?.render()
        }
    }

    private func render() {
        let docked = model.displayAttached
        statusLabel.text = (docked ? "Docked" : "No external display") + "  ·  " + model.mode.rawValue
        tabsLabel.text = model.tabs.enumerated().map { index, tab in
            (index == model.activeIndex ? "▸ " : "   ") + "\(index + 1). \(tab.displayTitle)"
        }.joined(separator: "\n")
        helpLabel.text = model.statusMessage.isEmpty ? BrowserModel.helpText : model.statusMessage

        webContainer.isHidden = docked
        tabsLabel.isHidden = !docked
        if !docked, let tab = model.activeTab {
            WebViewHost.attach(tab.webView, to: webContainer)
        }

        switch model.mode {
        case .insert:
            if !relayField.isFirstResponder { relayField.becomeFirstResponder() }
        case .normal, .hints:
            if relayField.isFirstResponder { relayField.resignFirstResponder() }
            if !urlField.isFirstResponder && !isFirstResponder { becomeFirstResponder() }
        }
    }

    // MARK: Command shortcuts (work in every mode)

    override var keyCommands: [UIKeyCommand]? { commandList }

    private lazy var commandList: [UIKeyCommand] = {
        var list: [UIKeyCommand] = []
        func add(_ input: String, _ flags: UIKeyModifierFlags, _ title: String, _ action: Selector) {
            let command = UIKeyCommand(title: title, action: action, input: input, modifierFlags: flags)
            command.wantsPriorityOverSystemBehavior = true
            list.append(command)
        }
        add("l", .command, "Open Location", #selector(cmdLocation))
        add("t", .command, "New Tab", #selector(cmdNewTab))
        add("t", [.command, .shift], "Reopen Closed Tab", #selector(cmdReopenTab))
        add("w", .command, "Close Tab", #selector(cmdCloseTab))
        add("r", .command, "Reload", #selector(cmdReload))
        add("[", .command, "Back", #selector(cmdBack))
        add("]", .command, "Forward", #selector(cmdForward))
        add("]", [.command, .shift], "Next Tab", #selector(cmdNextTab))
        add("[", [.command, .shift], "Previous Tab", #selector(cmdPrevTab))
        add("\t", .control, "Next Tab", #selector(cmdNextTab))
        add("\t", [.control, .shift], "Previous Tab", #selector(cmdPrevTab))
        add("=", .command, "Zoom In", #selector(cmdZoomIn))
        add("+", .command, "Zoom In", #selector(cmdZoomIn))
        add("-", .command, "Zoom Out", #selector(cmdZoomOut))
        add("0", .command, "Actual Size", #selector(cmdZoomReset))
        add(UIKeyCommand.inputEscape, [], "Cancel", #selector(cmdEscape))
        for n in 1...9 { add("\(n)", .command, "Tab \(n)", #selector(cmdSelectTab(_:))) }
        return list
    }()

    @objc private func cmdLocation() {
        if model.mode == .insert { model.leaveInsertMode() }
        if model.mode == .hints { model.cancelHints() }
        urlField.text = model.activeTab?.url?.absoluteString
        urlField.becomeFirstResponder()
        urlField.selectAll(nil)
    }

    @objc private func cmdNewTab() { model.newTab(); cmdLocation() }
    @objc private func cmdReopenTab() { model.reopenClosedTab() }
    @objc private func cmdCloseTab() { model.closeActiveTab() }
    @objc private func cmdReload() { model.reload() }
    @objc private func cmdBack() { model.goBack() }
    @objc private func cmdForward() { model.goForward() }
    @objc private func cmdNextTab() { model.nextTab() }
    @objc private func cmdPrevTab() { model.previousTab() }
    @objc private func cmdZoomIn() { model.zoom(by: 0.1) }
    @objc private func cmdZoomOut() { model.zoom(by: -0.1) }
    @objc private func cmdZoomReset() { model.resetZoom() }

    @objc private func cmdSelectTab(_ sender: UIKeyCommand) {
        if let input = sender.input, let n = Int(input) { model.selectTab(n - 1) }
    }

    @objc private func cmdEscape() {
        if urlField.isFirstResponder {
            urlField.resignFirstResponder()
            becomeFirstResponder()
            return
        }
        switch model.mode {
        case .hints: model.cancelHints()
        case .insert: model.leaveInsertMode()
        case .normal:
            model.stop()
            model.statusMessage = ""
        }
    }

    // MARK: Normal-mode keys (no modifier, nothing else focused)

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if !urlField.isFirstResponder, !relayField.isFirstResponder,
           let key = presses.first?.key, handleNormalKey(key) {
            return
        }
        super.pressesBegan(presses, with: event)
    }

    private func handleNormalKey(_ key: UIKey) -> Bool {
        if !key.modifierFlags.intersection([.command, .control, .alternate]).isEmpty { return false }
        let shift = key.modifierFlags.contains(.shift)
        let base = key.charactersIgnoringModifiers.lowercased()

        if model.mode == .hints {
            switch key.keyCode {
            case .keyboardEscape: model.cancelHints()
            case .keyboardDeleteOrBackspace: model.hintKey("backspace")
            default:
                if let c = base.first, c.isLetter { model.hintKey(String(c)) }
            }
            return true
        }

        switch key.keyCode {
        case .keyboardDownArrow: model.scroll(.line(1)); return true
        case .keyboardUpArrow: model.scroll(.line(-1)); return true
        case .keyboardPageDown: model.scroll(.page(1)); return true
        case .keyboardPageUp: model.scroll(.page(-1)); return true
        case .keyboardHome: model.scroll(.top); return true
        case .keyboardEnd: model.scroll(.bottom); return true
        case .keyboardSpacebar: model.scroll(.page(shift ? -1 : 1)); return true
        case .keyboardTab: model.focusNext(reverse: shift); return true
        case .keyboardReturnOrEnter: model.pressEnter(shift: shift); return true
        default: break
        }

        let now = Date().timeIntervalSinceReferenceDate
        defer { if base != "g" { pendingG = false } }

        switch (base, shift) {
        case ("j", false): model.scroll(.line(1))
        case ("k", false): model.scroll(.line(-1))
        case ("d", false): model.scroll(.halfPage(1))
        case ("u", false): model.scroll(.halfPage(-1))
        case ("g", true): model.scroll(.bottom)
        case ("g", false):
            if pendingG && now - pendingGTime < 1.0 {
                model.scroll(.top)
                pendingG = false
            } else {
                pendingG = true
                pendingGTime = now
            }
        case ("f", false): model.showHints(newTab: false)
        case ("f", true): model.showHints(newTab: true)
        case ("h", true): model.goBack()
        case ("l", true): model.goForward()
        case ("j", true): model.previousTab()
        case ("k", true): model.nextTab()
        case ("r", false): model.reload()
        case ("o", false), ("/", false): cmdLocation()
        case ("t", false): cmdNewTab()
        case ("x", false): model.closeActiveTab()
        default: return false
        }
        return true
    }

    // MARK: UITextFieldDelegate

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        if textField === urlField {
            model.navigate(urlField.text ?? "")
            urlField.resignFirstResponder()
            becomeFirstResponder()
        } else if textField === relayField {
            relayField.fireEnter()
        }
        return false
    }

    func textFieldDidEndEditing(_ textField: UITextField) {
        if textField === relayField, model.mode == .insert {
            // Keyboard dismissed by the system (e.g. app backgrounded): leave insert mode.
            model.leaveInsertMode()
        }
        if !urlField.isFirstResponder && !relayField.isFirstResponder { becomeFirstResponder() }
    }
}
