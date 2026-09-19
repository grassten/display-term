import UIKit
import Combine

/// Everything drawn on the external display: Safari-style toolbar (back/forward/reload,
/// URL bar, new tab), tab strip, the page, a status bar, the virtual cursor and the
/// right-click menu. This scene receives no touches; all pointer events come from
/// PointerController through the PointerSurface protocol and are dispatched here.
final class DesktopViewController: UIViewController, PointerSurface {
    private let model = BrowserModel.shared
    private var cancellable: AnyCancellable?
    private var renderScheduled = false

    private let toolbar = UIView()
    private let backButton = UIButton(type: .system)
    private let forwardButton = UIButton(type: .system)
    private let reloadButton = UIButton(type: .system)
    private let newTabButton = UIButton(type: .system)
    private let urlBar = UIView()
    private let urlLabel = UILabel()
    private let tabBar = UIView()
    private let tabStack = UIStackView()
    private let progressView = UIProgressView(progressViewStyle: .bar)
    private let webContainer = UIView()
    private let bottomBar = UIView()
    private let modeLabel = PaddedLabel()
    private let statusLabel = UILabel()
    private let cursorView = CursorView()
    private var contextMenu: ContextMenuView?

    private var hoveredControl: UIControl?
    private var pressedControl: UIControl?
    private var lastMoveSent: TimeInterval = 0
    private var pendingMove: (CGPoint, Int)?
    private var lastProbeTime: TimeInterval = 0

    private var scale: CGFloat { model.displayUIScale }

    // MARK: Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        toolbar.backgroundColor = UIColor(white: 0.14, alpha: 1)
        for (button, symbol, action) in [
            (backButton, "chevron.left", #selector(backTapped)),
            (forwardButton, "chevron.right", #selector(forwardTapped)),
            (reloadButton, "arrow.clockwise", #selector(reloadTapped)),
            (newTabButton, "plus", #selector(newTabTapped)),
        ] {
            button.setImage(UIImage(systemName: symbol), for: .normal)
            button.tintColor = UIColor(white: 0.85, alpha: 1)
            button.addTarget(self, action: action, for: .touchUpInside)
            toolbar.addSubview(button)
        }
        urlBar.backgroundColor = UIColor(white: 0.24, alpha: 1)
        urlBar.isUserInteractionEnabled = true
        urlLabel.textColor = UIColor(white: 0.9, alpha: 1)
        urlLabel.lineBreakMode = .byTruncatingMiddle
        urlBar.addSubview(urlLabel)
        toolbar.addSubview(urlBar)
        toolbar.addSubview(progressView)
        progressView.trackTintColor = .clear
        progressView.progressTintColor = .systemBlue

        tabBar.backgroundColor = UIColor(white: 0.10, alpha: 1)
        tabStack.axis = .horizontal
        tabStack.alignment = .center
        tabStack.distribution = .fill
        tabBar.addSubview(tabStack)

        webContainer.backgroundColor = .white
        bottomBar.backgroundColor = UIColor(white: 0.12, alpha: 1)
        modeLabel.textColor = .black
        modeLabel.backgroundColor = .systemYellow
        modeLabel.layer.cornerRadius = 4
        modeLabel.clipsToBounds = true
        statusLabel.textColor = UIColor(white: 0.75, alpha: 1)
        statusLabel.lineBreakMode = .byTruncatingTail
        bottomBar.addSubview(modeLabel)
        bottomBar.addSubview(statusLabel)

        view.addSubview(toolbar)
        view.addSubview(tabBar)
        view.addSubview(webContainer)
        view.addSubview(bottomBar)
        view.addSubview(cursorView)
        cursorView.isHidden = true

        cancellable = model.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.scheduleRender() }
        model.pointer.surface = self
        render()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let s = scale
        let b = view.bounds
        let toolbarH = 38 * s
        let tabH = 28 * s
        let bottomH = 22 * s
        let topH = toolbarH + tabH

        toolbar.frame = CGRect(x: 0, y: 0, width: b.width, height: toolbarH)
        let btn = 30 * s
        let gap = 6 * s
        var x = 8 * s
        for button in [backButton, forwardButton, reloadButton] {
            button.frame = CGRect(x: x, y: (toolbarH - btn) / 2, width: btn, height: btn)
            x += btn + gap
        }
        newTabButton.frame = CGRect(x: b.width - 8 * s - btn, y: (toolbarH - btn) / 2, width: btn, height: btn)
        let urlX = x + 4 * s
        urlBar.frame = CGRect(x: urlX, y: 5 * s, width: newTabButton.frame.minX - 10 * s - urlX, height: toolbarH - 10 * s)
        urlBar.layer.cornerRadius = 6 * s
        urlLabel.font = .systemFont(ofSize: 13 * s)
        urlLabel.frame = urlBar.bounds.insetBy(dx: 10 * s, dy: 0)
        progressView.frame = CGRect(x: 0, y: toolbarH - 2 * s, width: b.width, height: 2 * s)

        tabBar.frame = CGRect(x: 0, y: toolbarH, width: b.width, height: tabH)
        tabStack.spacing = 3 * s
        tabStack.frame = CGRect(x: 8 * s, y: 3 * s, width: b.width - 16 * s, height: tabH - 6 * s)

        webContainer.frame = CGRect(x: 0, y: topH, width: b.width, height: b.height - topH - bottomH)
        for sub in webContainer.subviews { sub.frame = webContainer.bounds }

        bottomBar.frame = CGRect(x: 0, y: b.height - bottomH, width: b.width, height: bottomH)
        modeLabel.font = .monospacedSystemFont(ofSize: 10 * s, weight: .bold)
        modeLabel.insets = UIEdgeInsets(top: 1.5 * s, left: 6 * s, bottom: 1.5 * s, right: 6 * s)
        modeLabel.sizeToFit()
        modeLabel.frame = CGRect(x: 8 * s, y: (bottomH - modeLabel.bounds.height) / 2,
                                 width: modeLabel.bounds.width, height: modeLabel.bounds.height)
        statusLabel.font = .systemFont(ofSize: 10.5 * s)
        let sx = modeLabel.frame.maxX + 10 * s
        statusLabel.frame = CGRect(x: sx, y: 0, width: b.width - sx - 8 * s, height: bottomH)

        cursorView.scale = s
        cursorView.place(at: model.pointer.position)
        view.bringSubviewToFront(cursorView)
        if let menu = contextMenu { view.bringSubviewToFront(menu); view.bringSubviewToFront(cursorView) }
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
        let s = scale

        for sub in tabStack.arrangedSubviews { sub.removeFromSuperview() }
        for (index, tab) in model.tabs.enumerated() {
            let active = index == model.activeIndex
            let button = UIButton(type: .custom)
            button.tag = index
            button.setTitle("\(tab.displayTitle)", for: .normal)
            button.setTitleColor(active ? .white : UIColor(white: 0.7, alpha: 1), for: .normal)
            button.setTitleColor(.white, for: .highlighted)
            button.titleLabel?.font = .systemFont(ofSize: 11.5 * s, weight: active ? .semibold : .regular)
            button.titleLabel?.lineBreakMode = .byTruncatingTail
            button.backgroundColor = active ? UIColor(white: 0.30, alpha: 1) : UIColor(white: 0.18, alpha: 1)
            button.layer.cornerRadius = 5 * s
            button.clipsToBounds = true
            button.contentEdgeInsets = UIEdgeInsets(top: 0, left: 10 * s, bottom: 0, right: 10 * s)
            button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            button.widthAnchor.constraint(lessThanOrEqualToConstant: 240 * s).isActive = true
            button.addTarget(self, action: #selector(tabTapped(_:)), for: .touchUpInside)
            tabStack.addArrangedSubview(button)
        }
        let spacer = UIView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        tabStack.addArrangedSubview(spacer)

        if let tab = model.activeTab {
            if model.isEditingURL {
                urlLabel.text = model.urlDraft + "▏"
                urlLabel.textColor = .white
            } else {
                urlLabel.text = tab.url?.absoluteString ?? ""
                urlLabel.textColor = UIColor(white: 0.9, alpha: 1)
            }
            urlBar.backgroundColor = model.isEditingURL ? UIColor(white: 0.32, alpha: 1) : UIColor(white: 0.24, alpha: 1)
            progressView.progress = Float(tab.progress)
            progressView.isHidden = tab.progress >= 1
            backButton.alpha = tab.canGoBack ? 1 : 0.35
            forwardButton.alpha = tab.canGoForward ? 1 : 0.35
            if model.displayAttached {
                WebViewHost.attach(tab.webView, to: webContainer)
            }
        }

        modeLabel.text = model.mode.rawValue
        switch model.mode {
        case .insert: modeLabel.backgroundColor = .systemGreen
        case .hints: modeLabel.backgroundColor = .systemOrange
        case .find: modeLabel.backgroundColor = .systemTeal
        case .normal: modeLabel.backgroundColor = .systemYellow
        }
        if model.mode == .find {
            let found = model.findMatched
            let suffix = found == nil ? "" : (found == true ? "  ✓" : "  — not found")
            statusLabel.text = "Find: \(model.findText)\(suffix)   (Enter next · ⇧Enter previous · Esc close)"
        } else {
            statusLabel.text = model.statusMessage.isEmpty ? BrowserModel.helpText : model.statusMessage
        }
        view.setNeedsLayout()
    }

    // MARK: Toolbar actions

    @objc private func backTapped() { model.goBack() }
    @objc private func forwardTapped() { model.goForward() }
    @objc private func reloadTapped() { model.reload() }
    @objc private func newTabTapped() { model.newTab(); model.requestURLEntry() }
    @objc private func tabTapped(_ sender: UIButton) { model.selectTab(sender.tag) }

    // MARK: PointerSurface

    var pointerBounds: CGRect { view.bounds }

    private func findControl(at point: CGPoint) -> UIControl? {
        var hit = view.hitTest(point, with: nil)
        while let v = hit {
            if let c = v as? UIControl { return c }
            if v === urlBar { return nil }
            hit = v.superview
        }
        return nil
    }

    private func isInWeb(_ point: CGPoint) -> Bool {
        webContainer.frame.contains(point) && contextMenu.map { !$0.frame.contains(point) } ?? true
    }

    private func cssPoint(_ point: CGPoint) -> CGPoint {
        let inWeb = view.convert(point, to: webContainer)
        return model.cssPoint(fromWebViewPoint: inWeb)
    }

    func pointerMoved(to point: CGPoint, buttons: Int) {
        cursorView.place(at: point)

        let control = findControl(at: point)
        if control !== hoveredControl {
            hoveredControl?.isHighlighted = false
            hoveredControl = control
            control?.isHighlighted = true
        }

        if isInWeb(point) {
            let now = Date().timeIntervalSinceReferenceDate
            if now - lastMoveSent >= 1.0 / 60.0 {
                lastMoveSent = now
                model.webPointerMove(cssPoint(point), buttons: buttons)
            } else if pendingMove == nil {
                pendingMove = (point, buttons)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 60.0) { [weak self] in
                    guard let self, let pending = self.pendingMove else { return }
                    self.pendingMove = nil
                    self.lastMoveSent = Date().timeIntervalSinceReferenceDate
                    self.model.webPointerMove(self.cssPoint(pending.0), buttons: pending.1)
                }
            } else {
                pendingMove = (point, buttons)
            }
            if now - lastProbeTime > 0.12 {
                lastProbeTime = now
                model.webProbe(at: cssPoint(point)) { [weak self] info in
                    guard let self, let css = info?["cursor"] as? String else { return }
                    self.cursorView.shape = CursorView.shape(forCSSCursor: css)
                    self.cursorView.place(at: self.model.pointer.position)
                }
            }
        } else {
            cursorView.shape = control != nil || urlBar.frame.contains(view.convert(point, to: toolbar)) ? .hand : .arrow
            cursorView.place(at: point)
        }
    }

    func pointerButton(_ button: PointerController.Button, pressed: Bool, at point: CGPoint,
                       clickCount: Int, modifiers: UIKeyModifierFlags) {
        if let menu = contextMenu {
            if menu.frame.contains(point) {
                if let control = findControl(at: point) {
                    if pressed { pressedControl = control } else { control.sendActions(for: .touchUpInside); pressedControl = nil }
                }
            } else if pressed {
                dismissContextMenu()
            }
            return
        }

        if isInWeb(point) {
            model.webPointerButton(button, pressed: pressed, at: cssPoint(point), clickCount: clickCount, modifiers: modifiers)
            if button == .right, !pressed {
                let css = cssPoint(point)
                model.webProbe(at: css) { [weak self] info in
                    self?.showContextMenu(at: point, info: info ?? [:])
                }
            }
            return
        }

        // Chrome: URL bar and controls
        let toolbarPoint = view.convert(point, to: toolbar)
        if urlBar.frame.contains(toolbarPoint) {
            if !pressed { model.requestURLEntry() }
            return
        }
        if let control = findControl(at: point) {
            if pressed {
                pressedControl = control
            } else {
                if pressedControl === control {
                    if button == .middle, control.superview === tabStack {
                        model.closeTab(at: control.tag)
                    } else if button == .left {
                        control.sendActions(for: .touchUpInside)
                    }
                }
                pressedControl = nil
            }
        }
    }

    func pointerScrolled(dx: CGFloat, dy: CGFloat, at point: CGPoint) {
        guard isInWeb(point) else { return }
        model.webScroll(at: cssPoint(point), dx: dx, dy: dy)
    }

    func pointerVisibilityChanged(_ visible: Bool) {
        cursorView.isHidden = !visible
    }

    // MARK: Context menu

    private func showContextMenu(at point: CGPoint, info: [String: Any]) {
        dismissContextMenu()
        let model = self.model
        var items: [ContextMenuView.Item] = []
        let href = info["href"] as? String
        let selection = (info["selection"] as? String) ?? ""
        let src = info["src"] as? String
        let editable = (info["editable"] as? Bool) ?? false

        if let href, let url = URL(string: href) {
            items.append(.init(title: "Open Link in New Tab") { [model] in model.newTab(url: url, select: false) })
            items.append(.init(title: "Open Link") { [model] in model.navigate(href) })
            items.append(.init(title: "Copy Link") { [model] in model.copyToPasteboard(href, label: "link") })
        }
        if let src, let url = URL(string: src) {
            items.append(.init(title: "Open Image in New Tab") { [model] in model.newTab(url: url, select: false) })
            items.append(.init(title: "Copy Image Address") { [model] in model.copyToPasteboard(src, label: "image address") })
        }
        if !selection.isEmpty {
            items.append(.init(title: "Copy") { [model] in model.copySelection() })
            items.append(.init(title: "Search Google for “\(selection.prefix(24))…”") { [model] in
                model.newTab(url: nil, select: true)
                model.navigate(selection)
            })
        }
        if editable {
            items.append(.init(title: "Paste") { [model] in model.paste() })
            items.append(.init(title: "Cut") { [model] in model.cut() })
            items.append(.init(title: "Select All") { [model] in model.selectAll() })
        }
        items.append(.init(title: "Back") { [model] in model.goBack() })
        items.append(.init(title: "Forward") { [model] in model.goForward() })
        items.append(.init(title: "Reload") { [model] in model.reload() })

        let menu = ContextMenuView(items: items, scale: scale)
        menu.onDismiss = { [weak self] in self?.dismissContextMenu() }
        view.addSubview(menu)
        menu.layoutIfNeeded()
        let size = menu.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize)
        var origin = point
        if origin.x + size.width > view.bounds.maxX { origin.x = view.bounds.maxX - size.width - 4 }
        if origin.y + size.height > view.bounds.maxY { origin.y = view.bounds.maxY - size.height - 4 }
        menu.frame = CGRect(origin: origin, size: size)
        contextMenu = menu
        view.bringSubviewToFront(cursorView)
    }

    func dismissContextMenu() {
        contextMenu?.removeFromSuperview()
        contextMenu = nil
    }
}
