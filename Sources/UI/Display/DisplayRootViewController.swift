import UIKit
import Combine
import SwiftTerm

/// The whole external display: tab bar, split panes, status bar, and the virtual cursor.
/// Receives no system input; pointer events arrive through `PointerSurface` from the phone.
final class DisplayRootViewController: UIViewController, PointerSurface {
    private let state = AppState.shared
    private var workspace: Workspace { state.workspace }

    private let tabBar = TabBarView()
    private let paneContainer = UIView()
    private let statusBar = StatusBarView()
    private let cursorView = CursorView()
    private let emptyLabel = UILabel()
    private var paneViews: [UUID: PaneView] = [:]
    private var dividerViews: [UIView] = []
    private var layoutCache = PaneLayout()
    private var appearance: [UUID: TerminalAppearance] = [:]
    private var cancellables = Set<AnyCancellable>()
    private var clockTimer: Timer?
    private var renderScheduled = false
    private var contextMenu: ContextMenuView?

    // Pointer interaction in progress.
    private var dividerDrag: (tab: Tab, divider: DividerLayout)?
    private var selectionAnchor: (pane: Pane, position: Position)?
    private var scrollAccumulator: CGFloat = 0

    /// Chrome scale: the display is laid out as if it were 1920 points wide.
    private var scale: CGFloat { max(1, view.bounds.width / 1920) }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        view.addSubview(paneContainer)
        view.addSubview(tabBar)
        view.addSubview(statusBar)
        emptyLabel.text = "No tabs. ⌘T opens one."
        emptyLabel.textColor = UIColor(white: 0.5, alpha: 1)
        emptyLabel.textAlignment = .center
        paneContainer.addSubview(emptyLabel)
        cursorView.isHidden = true
        view.addSubview(cursorView)

        workspace.objectWillChange.sink { [weak self] _ in self?.scheduleRender() }.store(in: &cancellables)
        state.preferences.objectWillChange.sink { [weak self] _ in
            self?.scheduleRender()
            self?.view.setNeedsLayout()
        }.store(in: &cancellables)
        state.themes.objectWillChange.sink { [weak self] _ in self?.scheduleRender() }.store(in: &cancellables)
        state.$chromeHidden.sink { [weak self] _ in self?.view.setNeedsLayout() }.store(in: &cancellables)
        clockTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in self?.updateStatus() }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        state.pointer.surface = self
        NSLog("[Display] root appeared bounds=\(view.bounds) scale=\(scale)")
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if state.pointer.surface === self { state.pointer.surface = nil }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let s = scale
        let b = view.bounds
        let tabH = state.chromeHidden ? 0 : round(26 * s)
        let statusH = state.chromeHidden || !state.preferences.showStatusBar ? 0 : round(22 * s)
        tabBar.scale = s
        tabBar.frame = CGRect(x: 0, y: 0, width: b.width, height: tabH)
        tabBar.isHidden = tabH == 0
        statusBar.scale = s
        statusBar.frame = CGRect(x: 0, y: b.height - statusH, width: b.width, height: statusH)
        statusBar.isHidden = statusH == 0
        paneContainer.frame = CGRect(x: 0, y: tabH, width: b.width, height: b.height - tabH - statusH)
        emptyLabel.font = .systemFont(ofSize: 14 * s)
        emptyLabel.frame = paneContainer.bounds
        cursorView.scale = s
        render()
    }

    private func scheduleRender() {
        guard !renderScheduled else { return }
        renderScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.renderScheduled = false
            self?.render()
        }
    }

    // MARK: Rendering

    private func render() {
        let s = scale
        let prefs = state.preferences
        guard let tab = workspace.activeTab else {
            paneViews.values.forEach { $0.isHidden = true }
            dividerViews.forEach { $0.isHidden = true }
            emptyLabel.isHidden = false
            tabBar.render(titles: [], active: 0)
            updateStatus()
            return
        }
        emptyLabel.isHidden = true
        tabBar.render(titles: workspace.tabs.map(\.title), active: workspace.activeIndex)

        let dividerThickness = max(1, round(1 * s))
        layoutCache = tab.layout(in: paneContainer.bounds, divider: dividerThickness)

        var live = Set<UUID>()
        for pane in tab.panes {
            live.insert(pane.id)
            let paneView = paneViews[pane.id] ?? makePaneView(for: pane)
            paneView.scale = s
            paneView.showsTitleBar = prefs.showPaneTitles
            paneView.dimAmount = CGFloat(prefs.dimInactivePanes)
            paneView.isActivePane = pane.id == tab.focusedPaneID || tab.panes.count == 1
            if let frame = layoutCache.frames[pane.id] {
                paneView.isHidden = false
                paneView.frame = frame
            } else {
                paneView.isHidden = true
            }
            paneView.attachTerminal()
            applyAppearance(to: pane)
            paneView.update()
        }
        // Panes in other tabs stay parented (their terminal views keep their size) but hidden.
        for (id, paneView) in paneViews where !live.contains(id) {
            paneView.isHidden = true
            if !workspace.allPanes.contains(where: { $0.id == id }) {
                paneView.removeFromSuperview()
                paneViews[id] = nil
                appearance[id] = nil
            }
        }

        while dividerViews.count < layoutCache.dividers.count {
            let v = UIView()
            v.backgroundColor = UIColor(white: 0.25, alpha: 1)
            paneContainer.addSubview(v)
            dividerViews.append(v)
        }
        for (i, v) in dividerViews.enumerated() {
            if i < layoutCache.dividers.count {
                v.isHidden = false
                v.frame = layoutCache.dividers[i].frame
                paneContainer.bringSubviewToFront(v)
            } else {
                v.isHidden = true
            }
        }
        if let menu = contextMenu { view.bringSubviewToFront(menu) }
        view.bringSubviewToFront(cursorView)
        updateStatus()
    }

    private func makePaneView(for pane: Pane) -> PaneView {
        let paneView = PaneView(pane: pane)
        paneContainer.addSubview(paneView)
        paneViews[pane.id] = paneView
        return paneView
    }

    private func applyAppearance(to pane: Pane) {
        let prefs = state.preferences
        let wanted = TerminalAppearance(fontSize: prefs.displayFontSize, themeName: prefs.themeName, optionAsMeta: state.keymap.optionAsMeta)
        guard appearance[pane.id] != wanted else { return }
        appearance[pane.id] = wanted
        wanted.apply(to: pane.terminalView, themes: state.themes)
    }

    private func updateStatus() {
        guard let pane = workspace.focusedPane else {
            statusBar.leading.text = "○ not connected"
            statusBar.middle.text = ""
            statusBar.trailing.text = state.preferences.showKeyHints ? "⌘T new tab · ⌘, settings" : ""
            statusBar.clock.text = Self.clockFormatter.string(from: Date())
            statusBar.setNeedsLayout()
            return
        }
        let dot = pane.state == .connected ? "●" : "○"
        statusBar.leading.text = "\(dot) \(pane.profile.user)@\(pane.profile.hostDisplay) · \(pane.authenticatedWith) · \(pane.state.text)"
        statusBar.middle.text = pane.cwd == nil ? "" : pane.titleBarText
        statusBar.trailing.text = state.preferences.showKeyHints
            ? "⌘D split · ⌘⇧D split down · ⌘⌥↔ pane · ⌘T tab · ⌘⇧↩ zoom pane · \(pane.cols)×\(pane.rows)"
            : "\(pane.cols)×\(pane.rows)"
        statusBar.clock.text = Self.clockFormatter.string(from: Date())
        statusBar.setNeedsLayout()
    }

    private static let clockFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    // MARK: PointerSurface

    var pointerBounds: CGRect { view.bounds }

    func pointerVisibilityChanged(_ visible: Bool) {
        cursorView.isHidden = !visible
    }

    func pointerMoved(to point: CGPoint, buttons: Int) {
        cursorView.place(at: point)
        if let menu = contextMenu {
            highlightMenuButton(menu, at: point)
            cursorView.shape = .arrow
            return
        }
        if let drag = dividerDrag {
            let local = view.convert(point, to: paneContainer)
            let f = drag.divider.splitFrame
            let ratio = drag.divider.axis == .vertical ? (local.x - f.minX) / max(1, f.width) : (local.y - f.minY) / max(1, f.height)
            drag.tab.setRatio(of: drag.divider.splitID, to: ratio)
            render()
            return
        }
        if let anchor = selectionAnchor, buttons & 1 != 0 {
            if let hit = paneHit(point), hit.pane === anchor.pane {
                anchor.pane.terminalView.selection.dragExtend(row: hit.position.row, col: hit.position.col)
            }
            return
        }
        if dividerHit(point) != nil {
            cursorView.shape = .hand
        } else if paneHit(point) != nil {
            cursorView.shape = .ibeam
        } else {
            cursorView.shape = .arrow
        }
    }

    func pointerButton(_ button: PointerController.Button, pressed: Bool, at point: CGPoint,
                       clickCount: Int, modifiers: UIKeyModifierFlags) {
        if let menu = contextMenu {
            guard pressed else { return }
            if let item = menuButton(menu, at: point) {
                item.sendActions(for: .touchUpInside)
            } else {
                dismissMenu()
            }
            return
        }
        switch button {
        case .left:
            if pressed {
                cursorView.pulse()
                if !tabBar.isHidden, let hit = tabBar.hit(view.convert(point, to: tabBar)) {
                    switch hit {
                    case .tab(let i): workspace.selectTab(i)
                    case .newTab: workspace.newTab()
                    }
                    return
                }
                if let tab = workspace.activeTab, let divider = dividerHit(point) {
                    dividerDrag = (tab, divider)
                    return
                }
                guard let hit = paneHit(point) else { return }
                if workspace.focusedPane !== hit.pane { workspace.focus(hit.pane) }
                let terminal = hit.pane.terminalView
                switch clickCount {
                case 2:
                    selectWord(in: hit.pane, at: hit.position)
                case 3:
                    terminal.selection.select(row: hit.position.row)
                default:
                    if forwardClick(hit.pane, at: hit.position, modifiers: modifiers) {
                        selectionAnchor = nil
                    } else {
                        terminal.selectNone()
                        // A soft start becomes a selection only once the pointer drags.
                        terminal.selection.setSoftStart(row: hit.position.row, col: hit.position.col)
                        selectionAnchor = (hit.pane, hit.position)
                    }
                }
            } else {
                if dividerDrag != nil {
                    dividerDrag = nil
                    workspace.changed()
                }
                selectionAnchor = nil
            }
        case .right:
            guard pressed, let hit = paneHit(point) else { return }
            if workspace.focusedPane !== hit.pane { workspace.focus(hit.pane) }
            showContextMenu(for: hit.pane, at: point)
        case .middle:
            break
        }
    }

    func pointerScrolled(dx: CGFloat, dy: CGFloat, at point: CGPoint) {
        if let menu = contextMenu {
            menu.scroll(by: dy)
            return
        }
        guard let hit = paneHit(point) else { return }
        let terminalView = hit.pane.terminalView
        let terminal = terminalView.getTerminal()
        let lineHeight = max(1, terminalView.bounds.height / CGFloat(max(1, hit.pane.rows)))
        scrollAccumulator += dy
        let lines = Int(scrollAccumulator / lineHeight)
        guard lines != 0 else { return }
        scrollAccumulator -= CGFloat(lines) * lineHeight
        let count = min(abs(lines), 10)
        if terminal.mouseMode != .off, terminalView.allowMouseReporting {
            // The program tracks the mouse (tmux, vim with mouse=a): wheel events.
            let flags = terminal.encodeButton(button: lines > 0 ? 5 : 4, release: false, shift: false, meta: false, control: false)
            for _ in 0..<count { terminal.sendEvent(buttonFlags: flags, x: hit.position.col, y: hit.position.row) }
        } else if terminal.isCurrentBufferAlternate {
            // Full-screen programs without mouse support (less, man): arrow keys.
            for _ in 0..<count { terminalView.sendArrow(lines > 0 ? .down : .up) }
        } else if lines > 0 {
            terminalView.scrollDown(lines: lines)
        } else {
            terminalView.scrollUp(lines: -lines)
        }
    }

    /// Reports a click to a program that asked for mouse events. False when none did, in
    /// which case the click is ours (focus, selection).
    private func forwardClick(_ pane: Pane, at position: Position, modifiers: UIKeyModifierFlags) -> Bool {
        let terminal = pane.terminalView.getTerminal()
        guard pane.terminalView.allowMouseReporting, terminal.mouseMode != .off else { return false }
        let shift = modifiers.contains(.shift), meta = modifiers.contains(.alternate), control = modifiers.contains(.control)
        terminal.sendEvent(buttonFlags: terminal.encodeButton(button: 0, release: false, shift: shift, meta: meta, control: control),
                           x: position.col, y: position.row)
        if terminal.mouseMode != .x10 {
            terminal.sendEvent(buttonFlags: terminal.encodeButton(button: 0, release: true, shift: shift, meta: meta, control: control),
                               x: position.col, y: position.row)
        }
        return true
    }

    // MARK: Hit testing

    private struct PaneHit {
        let pane: Pane
        /// Screen (viewport) coordinates, which is what the selection service's row/col API takes.
        let position: Position
        let local: CGPoint
    }

    private func paneHit(_ point: CGPoint) -> PaneHit? {
        for (_, paneView) in paneViews where !paneView.isHidden {
            let inPane = view.convert(point, to: paneView)
            guard paneView.terminalFrame.contains(inPane) else { continue }
            let terminal = paneView.pane.terminalView
            let local = view.convert(point, to: terminal)
            let pane = paneView.pane
            let cellW = terminal.bounds.width / CGFloat(max(1, pane.cols))
            let cellH = terminal.bounds.height / CGFloat(max(1, pane.rows))
            let col = min(max(0, Int(local.x / cellW)), max(0, pane.cols - 1))
            let row = min(max(0, Int(local.y / cellH)), max(0, pane.rows - 1))
            return PaneHit(pane: pane, position: Position(col: col, row: row), local: local)
        }
        return nil
    }

    private func dividerHit(_ point: CGPoint) -> DividerLayout? {
        let local = view.convert(point, to: paneContainer)
        let grab = 6 * scale
        return layoutCache.dividers.first { $0.frame.insetBy(dx: -grab, dy: -grab).contains(local) }
    }

    /// Double-click: select the word under the pointer. Reads the row back through the
    /// selection service, finds the word, then selects just that span.
    private func selectWord(in pane: Pane, at position: Position) {
        let selection = pane.terminalView.selection!
        selection.select(row: position.row)
        let chars = Array(selection.getSelectedText())
        guard position.col < chars.count else { selection.selectNone(); return }
        func isWord(_ c: Character) -> Bool { c.isLetter || c.isNumber || "_-./~".contains(c) }
        guard isWord(chars[position.col]) else { selection.selectNone(); return }
        var start = position.col, end = position.col
        while start > 0, isWord(chars[start - 1]) { start -= 1 }
        while end + 1 < chars.count, isWord(chars[end + 1]) { end += 1 }
        selection.startSelection(row: position.row, col: start)
        selection.dragExtend(row: position.row, col: end)
    }

    // MARK: Context menu

    private func showContextMenu(for pane: Pane, at point: CGPoint) {
        dismissMenu()
        let commands = Commands(state: state)
        let hasSelection = pane.terminalView.selectionActive
        let items: [ContextMenuView.Item] = [
            .init(title: "Copy", enabled: hasSelection) { commands.perform(KeyBinding("", .copy)) },
            .init(title: "Paste") { commands.perform(KeyBinding("", .paste)) },
            .init(title: "Select All") { commands.perform(KeyBinding("", .selectAll)) },
            .init(title: "Split Vertically") { commands.perform(KeyBinding("", .splitVertical)) },
            .init(title: "Split Horizontally") { commands.perform(KeyBinding("", .splitHorizontal)) },
            .init(title: "Maximize / Restore Pane") { commands.perform(KeyBinding("", .toggleMaximizePane)) },
            .init(title: "Clear Buffer") { pane.clearBuffer() },
            .init(title: "Reconnect") { pane.reconnectNow() },
            .init(title: "Close Pane") { commands.perform(KeyBinding("", .closePane)) },
        ]
        let menu = ContextMenuView(items: items, scale: scale, maxHeight: view.bounds.height * 0.7)
        menu.onDismiss = { [weak self] in self?.dismissMenu() }
        view.addSubview(menu)
        let size = menu.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize)
        var origin = point
        if origin.x + size.width > view.bounds.width { origin.x = view.bounds.width - size.width - 4 }
        if origin.y + size.height > view.bounds.height { origin.y = max(0, view.bounds.height - size.height - 4) }
        menu.frame = CGRect(origin: origin, size: size)
        menu.layoutIfNeeded()
        contextMenu = menu
        view.bringSubviewToFront(cursorView)
    }

    private func dismissMenu() {
        contextMenu?.removeFromSuperview()
        contextMenu = nil
    }

    private func menuButton(_ menu: ContextMenuView, at point: CGPoint) -> UIButton? {
        func search(_ v: UIView) -> UIButton? {
            for sub in v.subviews {
                if let b = sub as? UIButton, b.isEnabled, b.convert(b.bounds, to: view).contains(point) { return b }
                if let found = search(sub) { return found }
            }
            return nil
        }
        return menu.frame.contains(point) ? search(menu) : nil
    }

    private func highlightMenuButton(_ menu: ContextMenuView, at point: CGPoint) {
        func walk(_ v: UIView) {
            for sub in v.subviews {
                if let b = sub as? UIButton { b.isHighlighted = b.isEnabled && b.convert(b.bounds, to: view).contains(point) }
                walk(sub)
            }
        }
        walk(menu)
    }
}
