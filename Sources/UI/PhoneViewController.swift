import GameController
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
    private let handoffButton = UIButton(type: .system)

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
        relayField.placeholder = "Typing goes to the page"
        relayField.delegate = self
        relayField.onInsert = { [weak self] text in self?.model.insertText(text) }
        relayField.onDelete = { [weak self] in self?.model.deleteBackward() }
        relayField.onEnter = { [weak self] shift in self?.model.pressEnter(shift: shift) }
        relayField.onArrow = { [weak self] dir in self?.model.moveCaret(dir) }
        relayField.onTab = { [weak self] reverse in self?.model.focusNext(reverse: reverse) }
        relayField.onNavigationKey = { [weak self] code, shift in
            guard let self, !self.model.pageEditableFocused else { return false }
            switch code {
            case .keyboardDownArrow: self.model.scroll(.line(1))
            case .keyboardUpArrow: self.model.scroll(.line(-1))
            case .keyboardPageDown: self.model.scroll(.page(1))
            case .keyboardPageUp: self.model.scroll(.page(-1))
            case .keyboardHome: self.model.scroll(.top)
            case .keyboardEnd: self.model.scroll(.bottom)
            case .keyboardSpacebar: self.model.scroll(.page(shift ? -1 : 1))
            default: return false
            }
            return true
        }

        helpLabel.font = .systemFont(ofSize: 12)
        helpLabel.textColor = .secondaryLabel
        helpLabel.numberOfLines = 0

        touchpad.pointer = model.pointer
        touchpad.onZoom = { [weak self] delta in self?.model.zoom(by: delta) }

        handoffButton.titleLabel?.font = .systemFont(ofSize: 13, weight: .semibold)
        handoffButton.addTarget(self, action: #selector(toggleHandoff), for: .touchUpInside)

        let stack = UIStackView(arrangedSubviews: [statusLabel, urlField, findField, relayField, handoffButton, helpLabel, webContainer, touchpad])
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
        let finding = model.mode == .find ? "  ·  FIND" : ""
        statusLabel.text = (docked ? "Docked" : "No external display") + pointing + finding
        helpLabel.text = model.statusMessage.isEmpty ? BrowserModel.helpText : model.statusMessage

        // The page sits on the phone whenever there is no display, and also on demand so
        // the system keyboard can offer iCloud Keychain passwords for it.
        let pageOnPhone = !docked || model.handoffToPhone
        webContainer.isHidden = !pageOnPhone
        touchpad.isHidden = !docked || model.handoffToPhone
        findField.isHidden = model.mode != .find
        handoffButton.isHidden = !docked
        handoffButton.setTitle(model.handoffToPhone ? "Send page back to display"
                                                    : "Type on phone (AutoFill passwords)", for: .normal)
        // The relay field only exists to raise the on-screen keyboard.
        relayField.isHidden = hardwareKeyboardAttached || pageOnPhone
        if pageOnPhone, let tab = model.activeTab {
            WebViewHost.attach(tab.webView, to: webContainer)
        }

        // Typing always reaches the page. With a hardware keyboard every key is handled in
        // pressesBegan below; the relay field exists only to raise the on-screen keyboard
        // when there is no hardware one. It must not hold the keyboard otherwise, because
        // UITextField does not route hardware key input through insertText(_:) and the
        // text ends up sitting in the field on the phone instead of reaching the page.
        if model.handoffToPhone {
            // Let the web view own the keyboard so iOS shows the AutoFill bar above it.
            if relayField.isFirstResponder { relayField.resignFirstResponder() }
            if isFirstResponder { resignFirstResponder() }
        } else if model.mode == .find {
            if !findField.isFirstResponder { findField.becomeFirstResponder() }
        } else if hardwareKeyboardAttached {
            if relayField.isFirstResponder {
                relayField.text = ""
                relayField.resignFirstResponder()
            }
            if !urlField.isFirstResponder, !isFirstResponder { becomeFirstResponder() }
        } else if !urlField.isFirstResponder, !relayField.isFirstResponder {
            relayField.becomeFirstResponder()
        }
    }

    private var hardwareKeyboardAttached: Bool { GCKeyboard.coalesced != nil }

    @objc private func toggleHandoff() {
        model.handoffToPhone.toggle()
        model.statusMessage = model.handoffToPhone
            ? "Page is on the phone. Tap a field to use saved passwords."
            : ""
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
            if !urlField.isFirstResponder, !relayField.isFirstResponder, !findField.isFirstResponder, handlePageKey(key) {
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

    /// Every key that reaches the page. Plain letters are always text, never commands;
    /// the browser's shortcuts all live on the Command key and are UIKeyCommands.
    private func handlePageKey(_ key: UIKey) -> Bool {
        if !key.modifierFlags.intersection([.command, .control, .alternate]).isEmpty { return false }
        let shift = key.modifierFlags.contains(.shift)
        let editing = model.pageEditableFocused

        switch key.keyCode {
        case .keyboardDeleteOrBackspace: model.deleteBackward(); return true
        case .keyboardReturnOrEnter: model.pressEnter(shift: shift); return true
        case .keyboardTab: model.focusNext(reverse: shift); return true
        case .keyboardEscape: model.leaveInsertMode(); return true
        case .keyboardLeftArrow:
            if editing { model.moveCaret("ArrowLeft"); return true }
            return false
        case .keyboardRightArrow:
            if editing { model.moveCaret("ArrowRight"); return true }
            return false
        case .keyboardUpArrow:
            if editing { model.moveCaret("ArrowUp") } else { model.scroll(.line(-1)) }
            return true
        case .keyboardDownArrow:
            if editing { model.moveCaret("ArrowDown") } else { model.scroll(.line(1)) }
            return true
        case .keyboardPageDown: model.scroll(.page(1)); return true
        case .keyboardPageUp: model.scroll(.page(-1)); return true
        case .keyboardHome:
            if editing { return false }
            model.scroll(.top); return true
        case .keyboardEnd:
            if editing { return false }
            model.scroll(.bottom); return true
        case .keyboardSpacebar:
            if editing { model.insertText(" ") } else { model.scroll(.page(shift ? -1 : 1)) }
            return true
        default: break
        }

        // Anything that produces a printable character is text for the page.
        let characters = key.characters
        if !characters.isEmpty,
           characters.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) {
            model.insertText(characters)
            return true
        }
        return false
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
        if textField === relayField {
            // Keyboard dismissed by the system (e.g. app backgrounded): leave insert mode.
            model.leaveInsertMode()
        }
        if textField === findField, model.mode == .find {
            model.leaveFindMode()
        }
        if editingTextField == nil && !relayField.isFirstResponder { becomeFirstResponder() }
    }
}
