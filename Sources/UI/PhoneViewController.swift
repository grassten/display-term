import UIKit
import Combine

/// The phone-side controller. This is where iOS delivers hardware keyboard input, so every
/// shortcut, normal-mode key and insert-mode keystroke is handled here and applied to the
/// shared BrowserModel, which the display scene renders. While docked, the lower half of
/// the screen is a trackpad.
final class PhoneViewController: UIViewController, UITextFieldDelegate {
    private let model = BrowserModel.shared
    private var cancellable: AnyCancellable?
    private var renderScheduled = false

    private let statusLabel = UILabel()
    private var lastMouseCount = -1
    private let urlField = UITextField()
    private let findField = UITextField()
    private let relayField = RelayTextField()
    private let helpLabel = UILabel()
    private let webContainer = UIView()
    private let touchpad = TouchpadView()

    private var displayRegistration: Any?
    private var pendingG = false
    private var pendingGTime: TimeInterval = 0

    override var canBecomeFirstResponder: Bool { true }

    // MARK: Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        model.presenter = self
        model.urlEntryRequested = { [weak self] in self?.cmdLocation() }
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
        updatePointerLock()
    }

    /// GCMouse posts connect/disconnect without this, but raw movement deltas only reach
    /// the app while it holds the pointer lock. Without it a wired Magic Trackpad shows up
    /// as "mouse" in the status line and never moves the cursor.
    override var prefersPointerLocked: Bool { true }

    private func updatePointerLock() {
        setNeedsUpdateOfPrefersPointerLocked()
        let scene = view.window?.windowScene
        NSLog("[Pointer] lock requested; active=\(scene?.activationState.rawValue ?? -99) mice=\(model.mouseCount)")
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
        urlField.addTarget(self, action: #selector(urlEditingChanged), for: .editingChanged)
        urlField.addTarget(self, action: #selector(urlEditingBegan), for: .editingDidBegin)
        urlField.addTarget(self, action: #selector(urlEditingEnded), for: .editingDidEnd)

        findField.borderStyle = .roundedRect
        findField.placeholder = "Find in page (⌘F)"
        findField.autocapitalizationType = .none
        findField.autocorrectionType = .no
        findField.returnKeyType = .search
        findField.delegate = self
        findField.addTarget(self, action: #selector(findEditingChanged), for: .editingChanged)
        findField.isHidden = true

        relayField.borderStyle = .roundedRect
        relayField.placeholder = "Typing goes to the page (Esc to stop)"
        relayField.delegate = self
        relayField.onInsert = { [weak self] text in self?.model.insertText(text) }
        relayField.onDelete = { [weak self] in self?.model.deleteBackward() }
        relayField.onEnter = { [weak self] shift in self?.model.pressEnter(shift: shift) }
        relayField.onArrow = { [weak self] dir in self?.model.moveCaret(dir) }
        relayField.onTab = { [weak self] reverse in self?.model.focusNext(reverse: reverse) }

        helpLabel.font = .systemFont(ofSize: 12)
        helpLabel.textColor = .secondaryLabel
        helpLabel.numberOfLines = 0

        touchpad.pointer = model.pointer
        touchpad.onZoom = { [weak self] delta in self?.model.zoom(by: delta) }

        let stack = UIStackView(arrangedSubviews: [statusLabel, urlField, findField, relayField, helpLabel, webContainer, touchpad])
        stack.axis = .vertical
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            stack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -12),
            stack.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -8),
        ])
        webContainer.setContentHuggingPriority(.defaultLow, for: .vertical)
        touchpad.setContentHuggingPriority(.defaultLow, for: .vertical)
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
        if model.mouseCount != lastMouseCount {
            lastMouseCount = model.mouseCount
            updatePointerLock()
        }
        let pointing = model.mouseCount > 0 ? " · mouse" : ""
        statusLabel.text = (docked ? "Docked" : "No external display") + pointing + "  ·  " + model.mode.rawValue
        helpLabel.text = model.statusMessage.isEmpty ? BrowserModel.helpText : model.statusMessage

        webContainer.isHidden = docked
        touchpad.isHidden = !docked
        findField.isHidden = model.mode != .find
        if !docked, let tab = model.activeTab {
            WebViewHost.attach(tab.webView, to: webContainer)
        }

        switch model.mode {
        case .insert:
            if !relayField.isFirstResponder { relayField.becomeFirstResponder() }
        case .find:
            if !findField.isFirstResponder { findField.becomeFirstResponder() }
        case .normal, .hints:
            if relayField.isFirstResponder { relayField.resignFirstResponder() }
            if findField.isFirstResponder { findField.resignFirstResponder() }
            if !urlField.isFirstResponder && !isFirstResponder { becomeFirstResponder() }
        }
    }

    private var editingTextField: UITextField? {
        if urlField.isFirstResponder { return urlField }
        if findField.isFirstResponder { return findField }
        return nil
    }

    // MARK: URL / find field events

    @objc private func urlEditingBegan() { model.isEditingURL = true; model.urlDraft = urlField.text ?? "" }
    @objc private func urlEditingChanged() { model.urlDraft = urlField.text ?? "" }
    @objc private func urlEditingEnded() { model.isEditingURL = false }
    @objc private func findEditingChanged() { model.find(findField.text ?? "") }

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
        add("f", .command, "Find", #selector(cmdFind))
        add("g", .command, "Find Next", #selector(cmdFindNext))
        add("g", [.command, .shift], "Find Previous", #selector(cmdFindPrevious))
        add("c", .command, "Copy", #selector(cmdCopy))
        add("v", .command, "Paste", #selector(cmdPaste))
        add("x", .command, "Cut", #selector(cmdCut))
        add("a", .command, "Select All", #selector(cmdSelectAll))
        add(UIKeyCommand.inputEscape, [], "Cancel", #selector(cmdEscape))
        for n in 1...9 { add("\(n)", .command, "Tab \(n)", #selector(cmdSelectTab(_:))) }
        return list
    }()

    @objc func cmdLocation() {
        if model.mode == .insert { model.leaveInsertMode() }
        if model.mode == .hints { model.cancelHints() }
        if model.mode == .find { model.leaveFindMode() }
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

    @objc private func cmdFind() {
        if urlField.isFirstResponder { urlField.resignFirstResponder() }
        findField.text = model.findText
        model.enterFindMode()
    }

    @objc private func cmdFindNext() { model.findNext() }
    @objc private func cmdFindPrevious() { model.findPrevious() }

    @objc private func cmdCopy() {
        if let field = editingTextField { field.copy(nil) } else { model.copySelection() }
    }

    @objc private func cmdPaste() {
        if let field = editingTextField { field.paste(nil); if field === urlField { urlEditingChanged() } else { findEditingChanged() } }
        else if model.mode == .insert { model.paste() }
        else { model.statusMessage = "Nothing to paste into (focus a text field first)" }
    }

    @objc private func cmdCut() {
        if let field = editingTextField { field.cut(nil) } else if model.mode == .insert { model.cut() }
    }

    @objc private func cmdSelectAll() {
        if let field = editingTextField { field.selectAll(nil) } else { model.selectAll() }
    }

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
        case .find:
            model.leaveFindMode()
            findField.resignFirstResponder()
            becomeFirstResponder()
        case .normal:
            model.stop()
            model.statusMessage = ""
        }
    }

    // MARK: Key presses: modifier tracking for the pointer, then normal-mode keys

    private static func modifierFlag(for keyCode: UIKeyboardHIDUsage) -> UIKeyModifierFlags {
        switch keyCode {
        case .keyboardLeftShift, .keyboardRightShift: return .shift
        case .keyboardLeftGUI, .keyboardRightGUI: return .command
        case .keyboardLeftControl, .keyboardRightControl: return .control
        case .keyboardLeftAlt, .keyboardRightAlt: return .alternate
        default: return []
        }
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if let key = presses.first?.key {
            model.pointer.modifiers = key.modifierFlags.intersection([.shift, .command, .control, .alternate])
            if !urlField.isFirstResponder, !relayField.isFirstResponder, !findField.isFirstResponder, handleNormalKey(key) {
                return
            }
        }
        super.pressesBegan(presses, with: event)
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if let key = presses.first?.key {
            var flags = key.modifierFlags.intersection([.shift, .command, .control, .alternate])
            flags.remove(Self.modifierFlag(for: key.keyCode))
            model.pointer.modifiers = flags
        }
        super.pressesEnded(presses, with: event)
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
        } else if textField === findField {
            model.find(findField.text ?? "", forward: !model.pointer.modifiers.contains(.shift))
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
        if textField === findField, model.mode == .find {
            model.leaveFindMode()
        }
        if editingTextField == nil && !relayField.isFirstResponder { becomeFirstResponder() }
    }
}
