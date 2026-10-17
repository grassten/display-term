import UIKit
import Combine
import SwiftUI
import SwiftTerm

/// The phone. Undocked: tabs and the focused pane's terminal. Docked: status, touch actions,
/// the trackpad, and the key relay that forwards the hardware keyboard to the display.
/// Every keyboard shortcut is a UIKeyCommand here, in both modes.
final class PhoneRootViewController: UIViewController, CommandUI {
    private let state = AppState.shared
    private var workspace: Workspace { state.workspace }
    private lazy var commands: Commands = {
        let c = Commands(state: state)
        c.ui = self
        return c
    }()
    private var cancellables = Set<AnyCancellable>()
    private var renderScheduled = false
    private var displayRegistration: Any?
    private var presentedConnect = false

    private let header = UIView()
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let settingsButton = UIButton(type: .system)
    private let actions = UIStackView()
    private let touchpad = TouchpadView()
    private let keyRelay = KeyRelayView()
    private let relayKeys = ExtraKeysView()
    private let tabsStrip = UIScrollView()
    private let tabsStack = UIStackView()
    private let paneHost = UIView()
    private var paneViews: [UUID: PaneView] = [:]
    private var paneKeys: [UUID: ExtraKeysView] = [:]
    private var appearance: [UUID: TerminalAppearance] = [:]
    private var shownPaneID: UUID?

    override var canBecomeFirstResponder: Bool { true }

    // MARK: Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        PromptCenter.shared.presenter = self
        buildLayout()
        registerDisplayAccessoryIfNeeded()

        state.$displayAttached.sink { [weak self] _ in self?.scheduleRender() }.store(in: &cancellables)
        state.$statusMessage.sink { [weak self] _ in self?.scheduleRender() }.store(in: &cancellables)
        workspace.objectWillChange.sink { [weak self] _ in self?.scheduleRender() }.store(in: &cancellables)
        state.preferences.objectWillChange.sink { [weak self] _ in self?.scheduleRender() }.store(in: &cancellables)
        state.profiles.objectWillChange.sink { [weak self] _ in self?.scheduleRender() }.store(in: &cancellables)
        NotificationCenter.default.addObserver(forName: UIScene.didActivateNotification, object: nil, queue: .main) { [weak self] _ in
            self?.setNeedsUpdateOfScreenEdgesDeferringSystemGestures()
            self?.setNeedsUpdateOfHomeIndicatorAutoHidden()
            self?.scheduleRender()
        }
        render()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if let screen = view.window?.windowScene?.screen {
            state.pointer.phoneScreenSize = screen.bounds.size
        }
        ensureFirstRun()
        render()
    }

    /// While docked the phone is a trackpad: keep edge swipes from backgrounding the app.
    override var preferredScreenEdgesDeferringSystemGestures: UIRectEdge { state.displayAttached ? .all : [] }
    override var prefersHomeIndicatorAutoHidden: Bool { state.displayAttached }

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
        titleLabel.text = "Display Term"
        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        titleLabel.textColor = .white
        subtitleLabel.font = .systemFont(ofSize: 11)
        subtitleLabel.textColor = UIColor(white: 0.6, alpha: 1)
        subtitleLabel.numberOfLines = 2
        settingsButton.setTitle("Settings", for: .normal)
        settingsButton.titleLabel?.font = .systemFont(ofSize: 14)
        settingsButton.addAction(UIAction { [weak self] _ in self?.openSettings() }, for: .touchUpInside)
        let titles = UIStackView(arrangedSubviews: [titleLabel, subtitleLabel])
        titles.axis = .vertical
        titles.spacing = 1
        let headerRow = UIStackView(arrangedSubviews: [titles, settingsButton])
        headerRow.alignment = .center
        headerRow.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(headerRow)
        NSLayoutConstraint.activate([
            headerRow.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            headerRow.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            headerRow.topAnchor.constraint(equalTo: header.topAnchor),
            headerRow.bottomAnchor.constraint(equalTo: header.bottomAnchor),
        ])

        actions.axis = .horizontal
        actions.spacing = 8
        actions.distribution = .fillEqually
        for (title, caption, action) in [("⌘T", "new tab", TermAction.newTab), ("⌘D", "split", .splitVertical),
                                         ("⌘⇧D", "split down", .splitHorizontal), ("⌘W", "close", .closePane)] {
            var config = UIButton.Configuration.filled()
            config.title = title
            config.subtitle = caption
            config.titleAlignment = .center
            config.baseBackgroundColor = UIColor(white: 0.11, alpha: 1)
            config.baseForegroundColor = .white
            config.cornerStyle = .medium
            let button = UIButton(configuration: config)
            button.addAction(UIAction { [weak self] _ in self?.commands.perform(KeyBinding("", action)) }, for: .touchUpInside)
            actions.addArrangedSubview(button)
        }

        touchpad.pointer = state.pointer
        touchpad.layer.cornerRadius = 16
        touchpad.clipsToBounds = true
        touchpad.backgroundColor = UIColor(white: 0.09, alpha: 1)

        tabsStrip.showsHorizontalScrollIndicator = false
        tabsStack.axis = .horizontal
        tabsStack.spacing = 6
        tabsStack.translatesAutoresizingMaskIntoConstraints = false
        tabsStrip.addSubview(tabsStack)
        NSLayoutConstraint.activate([
            tabsStack.leadingAnchor.constraint(equalTo: tabsStrip.contentLayoutGuide.leadingAnchor),
            tabsStack.trailingAnchor.constraint(equalTo: tabsStrip.contentLayoutGuide.trailingAnchor),
            tabsStack.topAnchor.constraint(equalTo: tabsStrip.contentLayoutGuide.topAnchor),
            tabsStack.bottomAnchor.constraint(equalTo: tabsStrip.contentLayoutGuide.bottomAnchor),
            tabsStack.heightAnchor.constraint(equalTo: tabsStrip.frameLayoutGuide.heightAnchor),
            tabsStrip.heightAnchor.constraint(equalToConstant: 30),
        ])

        keyRelay.target = { [weak self] in self?.workspace.focusedPane?.terminalView }
        relayKeys.target = { [weak self] in self?.workspace.focusedPane?.terminalView }
        relayKeys.menuProvider = { [weak self] in self?.actionMenu() ?? UIMenu() }
        keyRelay.setAccessory(relayKeys)
        view.addSubview(keyRelay)

        let stack = UIStackView(arrangedSubviews: [header, actions, tabsStrip, paneHost, touchpad])
        stack.axis = .vertical
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 6),
            stack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -12),
            stack.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor, constant: -8),
        ])
        paneHost.setContentHuggingPriority(.defaultLow, for: .vertical)
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
        let docked = state.displayAttached
        actions.isHidden = !docked
        touchpad.isHidden = !docked
        tabsStrip.isHidden = docked
        paneHost.isHidden = docked

        if let pane = workspace.focusedPane, let tab = workspace.activeTab {
            let paneIndex = (tab.panes.firstIndex { $0.id == pane.id } ?? 0) + 1
            var line = "\(pane.state == .connected ? "●" : "○") \(pane.profile.user)@\(pane.profile.hostDisplay) · tab \(workspace.activeIndex + 1)/\(workspace.tabs.count) · pane \(paneIndex)/\(tab.panes.count) · \(pane.state.text)"
            if docked, let screen = state.displayScreen { line += "\nDocked · \(Int(screen.bounds.width))×\(Int(screen.bounds.height))" }
            if !state.statusMessage.isEmpty { line += "\n\(state.statusMessage)" }
            subtitleLabel.text = line
        } else {
            subtitleLabel.text = docked ? "Docked · no tabs (⌘T)" : (state.statusMessage.isEmpty ? "No tabs. ⌘T or the + above." : state.statusMessage)
        }

        if docked {
            // The display owns the terminal views; the phone relays keys and pointer.
            shownPaneID = nil
            if !keyRelay.isFirstResponder, presentedViewController == nil { keyRelay.becomeFirstResponder() }
        } else {
            renderTabs()
            showFocusedPane()
        }
        setNeedsUpdateOfScreenEdgesDeferringSystemGestures()
        setNeedsUpdateOfHomeIndicatorAutoHidden()
    }

    private func renderTabs() {
        tabsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (i, tab) in workspace.tabs.enumerated() {
            var config = UIButton.Configuration.filled()
            config.title = "\(i + 1) \(tab.title)" + (tab.panes.count > 1 ? " · \(tab.panes.count)" : "")
            config.baseBackgroundColor = i == workspace.activeIndex ? UIColor(white: 0.2, alpha: 1) : UIColor(white: 0.11, alpha: 1)
            config.baseForegroundColor = i == workspace.activeIndex ? .white : UIColor(white: 0.6, alpha: 1)
            config.cornerStyle = .medium
            config.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 10, bottom: 4, trailing: 10)
            config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attrs in
                var a = attrs
                a.font = UIFont.systemFont(ofSize: 12, weight: .medium)
                return a
            }
            let button = UIButton(configuration: config)
            button.addAction(UIAction { [weak self] _ in self?.workspace.selectTab(i) }, for: .touchUpInside)
            button.menu = UIMenu(children: [
                UIAction(title: "Next pane") { [weak self] _ in self?.workspace.cyclePane(by: 1) },
                UIAction(title: "Close tab", attributes: .destructive) { [weak self] _ in self?.workspace.closeTab(tab) },
            ])
            tabsStack.addArrangedSubview(button)
        }
        var plus = UIButton.Configuration.filled()
        plus.title = "+"
        plus.baseBackgroundColor = UIColor(white: 0.11, alpha: 1)
        plus.baseForegroundColor = .white
        plus.cornerStyle = .medium
        plus.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12)
        let plusButton = UIButton(configuration: plus)
        plusButton.addAction(UIAction { [weak self] _ in self?.workspace.newTab() }, for: .touchUpInside)
        tabsStack.addArrangedSubview(plusButton)
    }

    private func showFocusedPane() {
        guard let pane = workspace.focusedPane else {
            paneViews.values.forEach { $0.isHidden = true }
            return
        }
        let paneView = paneViews[pane.id] ?? {
            let v = PaneView(pane: pane)
            v.showsTitleBar = false
            v.translatesAutoresizingMaskIntoConstraints = false
            paneHost.addSubview(v)
            NSLayoutConstraint.activate([
                v.leadingAnchor.constraint(equalTo: paneHost.leadingAnchor),
                v.trailingAnchor.constraint(equalTo: paneHost.trailingAnchor),
                v.topAnchor.constraint(equalTo: paneHost.topAnchor),
                v.bottomAnchor.constraint(equalTo: paneHost.bottomAnchor),
            ])
            paneViews[pane.id] = v
            return v
        }()
        for (id, v) in paneViews where id != pane.id { v.isHidden = true }
        for (id, v) in paneViews where !workspace.allPanes.contains(where: { $0.id == id }) {
            v.removeFromSuperview()
            paneViews[id] = nil
            paneKeys[id] = nil
            appearance[id] = nil
        }
        paneView.isHidden = false
        paneView.isActivePane = true
        paneView.attachTerminal()
        paneView.update()

        let terminal = pane.terminalView
        let keys = paneKeys[pane.id] ?? {
            let k = ExtraKeysView()
            k.target = { terminal }
            k.menuProvider = { [weak self] in self?.actionMenu() ?? UIMenu() }
            paneKeys[pane.id] = k
            return k
        }()
        terminal.inputAccessoryView = keys
        let prefs = state.preferences
        let wanted = TerminalAppearance(fontSize: prefs.phoneFontSize, themeName: prefs.themeName, optionAsMeta: state.keymap.optionAsMeta)
        if appearance[pane.id] != wanted {
            appearance[pane.id] = wanted
            wanted.apply(to: terminal, themes: state.themes)
        }
        if shownPaneID != pane.id || !terminal.isFirstResponder {
            shownPaneID = pane.id
            if presentedViewController == nil {
                if keyRelay.isFirstResponder { keyRelay.resignFirstResponder() }
                terminal.becomeFirstResponder()
            }
        }
        pane.onBell = { UINotificationFeedbackGenerator().notificationOccurred(.warning) }
    }

    // MARK: First run

    private func ensureFirstRun() {
        guard !presentedConnect, presentedViewController == nil else { return }
        if state.profiles.profiles.isEmpty {
            presentedConnect = true
            presentConnect()
        } else if workspace.tabs.isEmpty {
            workspace.newTab()
        }
    }

    private func presentConnect() {
        let browser = HostBrowser()
        browser.start()
        let editor = ProfileEditor(profile: nil, browser: browser, profiles: state.profiles) { [weak self] profile in
            self?.dismiss(animated: true) {
                self?.workspace.newTab(profile: profile)
                self?.render()
            }
        }
        let host = UIHostingController(rootView: NavigationStack { editor }.preferredColorScheme(.dark))
        host.isModalInPresentation = true
        present(host, animated: true)
    }

    // MARK: CommandUI

    func openSettings() {
        guard presentedViewController == nil else { return }
        let root = SettingsRoot(profiles: state.profiles, preferences: state.preferences, keymap: state.keymap, themes: state.themes,
                                onConnect: { [weak self] profile in
                                    self?.dismiss(animated: true) { self?.workspace.newTab(profile: profile) }
                                },
                                onDone: { [weak self] in self?.dismiss(animated: true) { self?.render() } })
        let host = UIHostingController(rootView: root.preferredColorScheme(.dark))
        present(host, animated: true)
    }

    func toggleChrome() {
        state.chromeHidden.toggle()
    }

    private func actionMenu() -> UIMenu {
        var groups: [String: [UIAction]] = [:]
        var order: [String] = []
        for binding in state.keymap.bindings {
            if groups[binding.action.group] == nil { order.append(binding.action.group) }
            let title = binding.action.title + (binding.arg.map { " \($0)" } ?? "")
            groups[binding.action.group, default: []].append(UIAction(title: title, subtitle: binding.displayKeys) { [weak self] _ in
                self?.commands.perform(binding)
            })
        }
        return UIMenu(children: order.map { UIMenu(title: $0, options: .displayInline, children: groups[$0] ?? []) })
    }

    // MARK: Keyboard shortcuts

    override var keyCommands: [UIKeyCommand]? {
        state.keymap.keyCommands(action: #selector(runKeyCommand(_:)))
    }

    @objc private func runKeyCommand(_ command: UIKeyCommand) {
        guard let index = command.propertyList as? Int, let binding = state.keymap.binding(at: index) else { return }
        commands.perform(binding)
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if let key = presses.first?.key {
            state.pointer.modifiers = key.modifierFlags.intersection([.shift, .command, .control, .alternate])
        }
        super.pressesBegan(presses, with: event)
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if let key = presses.first?.key {
            state.pointer.modifiers = key.modifierFlags.intersection([.shift, .command, .control, .alternate]).subtracting(Self.modifierFlag(for: key.keyCode))
        }
        super.pressesEnded(presses, with: event)
    }

    private static func modifierFlag(for keyCode: UIKeyboardHIDUsage) -> UIKeyModifierFlags {
        switch keyCode {
        case .keyboardLeftShift, .keyboardRightShift: return .shift
        case .keyboardLeftGUI, .keyboardRightGUI: return .command
        case .keyboardLeftControl, .keyboardRightControl: return .control
        case .keyboardLeftAlt, .keyboardRightAlt: return .alternate
        default: return []
        }
    }
}
