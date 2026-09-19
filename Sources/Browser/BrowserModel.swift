import UIKit
import WebKit
import Combine

/// Shared state for both scenes: tabs, input mode, zoom, navigation, scrolling.
final class BrowserModel: NSObject, ObservableObject {
    static let shared = BrowserModel()

    static let desktopUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15"
    static let homeURL = URL(string: "https://www.google.com/")!
    static let helpText = "f links · F new tab · j/k scroll · d/u half page · gg/G top/bottom · H/L back/fwd · J/K tabs · o/⌘L url · t/⌘T new tab · x/⌘W close · Esc"

    enum Mode: String { case normal = "NORMAL", insert = "INSERT", hints = "HINTS" }

    enum ScrollAction { case line(Int), halfPage(Int), page(Int), top, bottom }

    @Published private(set) var tabs: [Tab] = []
    @Published private(set) var activeIndex: Int = 0
    @Published private(set) var displayAttached = false
    @Published private(set) var displayScreen: UIScreen?
    @Published var mode: Mode = .normal
    @Published private(set) var pageZoom: CGFloat = 1.0
    @Published var statusMessage: String = ""

    /// View controller used to present JavaScript alerts (always the phone, where taps work).
    weak var presenter: UIViewController?

    private let processPool = WKProcessPool()
    private var tabSinks: [UUID: AnyCancellable] = [:]
    private var closedURLs: [URL] = []

    var activeTab: Tab? { tabs.indices.contains(activeIndex) ? tabs[activeIndex] : nil }

    /// UI scale for chrome drawn on the external display (1x on a 4K panel is unreadable).
    var displayUIScale: CGFloat {
        guard let screen = displayScreen else { return 1 }
        return screen.bounds.width >= 3000 ? 2.0 : 1.5
    }

    override init() {
        super.init()
        newTab(url: Self.homeURL)
    }

    // MARK: Tabs

    private func makeConfiguration() -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration()
        config.processPool = processPool
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.defaultWebpagePreferences.preferredContentMode = .desktop
        config.preferences.isElementFullscreenEnabled = true
        config.userContentController.addUserScript(Bridge.userScript)
        config.userContentController.add(Bridge.shared, name: Bridge.handlerName)
        return config
    }

    @discardableResult
    func newTab(url: URL? = nil, configuration: WKWebViewConfiguration? = nil, select: Bool = true) -> Tab {
        let tab = Tab(configuration: configuration ?? makeConfiguration())
        tab.webView.navigationDelegate = self
        tab.webView.uiDelegate = self
        tab.webView.pageZoom = pageZoom
        tabs.append(tab)
        tabSinks[tab.id] = tab.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        if select { activeIndex = tabs.count - 1; mode = .normal }
        if let url { tab.load(url) }
        return tab
    }

    func closeActiveTab() {
        guard let tab = activeTab else { return }
        if let url = tab.url { closedURLs.append(url) }
        tabSinks[tab.id] = nil
        tab.webView.removeFromSuperview()
        tabs.remove(at: activeIndex)
        if tabs.isEmpty {
            newTab(url: Self.homeURL)
        } else {
            activeIndex = min(activeIndex, tabs.count - 1)
        }
        mode = .normal
    }

    func reopenClosedTab() {
        guard let url = closedURLs.popLast() else { statusMessage = "No closed tabs"; return }
        newTab(url: url)
    }

    func selectTab(_ index: Int) {
        guard tabs.indices.contains(index) else { return }
        activeIndex = index
        mode = .normal
    }

    func nextTab() { guard !tabs.isEmpty else { return }; selectTab((activeIndex + 1) % tabs.count) }
    func previousTab() { guard !tabs.isEmpty else { return }; selectTab((activeIndex - 1 + tabs.count) % tabs.count) }

    // MARK: Navigation

    func navigate(_ raw: String) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let url: URL
        if let u = URL(string: text), let scheme = u.scheme?.lowercased(), ["http", "https", "about"].contains(scheme) {
            url = u
        } else if !text.contains(" "), text.contains("."), let u = URL(string: "https://" + text) {
            url = u
        } else {
            var components = URLComponents(string: "https://www.google.com/search")!
            components.queryItems = [URLQueryItem(name: "q", value: text)]
            url = components.url!
        }
        if let tab = activeTab { tab.load(url) } else { newTab(url: url) }
        mode = .normal
    }

    func goBack() { activeTab?.webView.goBack() }
    func goForward() { activeTab?.webView.goForward() }
    func reload() { activeTab?.webView.reload() }
    func stop() { activeTab?.webView.stopLoading() }

    // MARK: Zoom

    func zoom(by delta: CGFloat) { setZoom(pageZoom + delta) }
    func resetZoom() { setZoom(defaultZoom()) }

    private func defaultZoom() -> CGFloat {
        guard displayAttached, let screen = displayScreen else { return 1.0 }
        return screen.bounds.width >= 3000 ? 2.0 : 1.5
    }

    private func setZoom(_ value: CGFloat) {
        pageZoom = min(max(value, 0.5), 4.0)
        for tab in tabs { tab.webView.pageZoom = pageZoom }
        statusMessage = "Zoom \(Int((pageZoom * 100).rounded()))%"
    }

    // MARK: Scrolling (native, works on every page)

    func scroll(_ action: ScrollAction) {
        guard let scrollView = activeTab?.webView.scrollView else { return }
        let height = scrollView.bounds.height
        var offset = scrollView.contentOffset
        switch action {
        case .line(let d): offset.y += CGFloat(d) * 90
        case .halfPage(let d): offset.y += CGFloat(d) * height * 0.5
        case .page(let d): offset.y += CGFloat(d) * height * 0.9
        case .top: offset.y = -scrollView.adjustedContentInset.top
        case .bottom: offset.y = .greatestFiniteMagnitude
        }
        let minY = -scrollView.adjustedContentInset.top
        let maxY = max(minY, scrollView.contentSize.height - height + scrollView.adjustedContentInset.bottom)
        offset.y = min(max(offset.y, minY), maxY)
        scrollView.setContentOffset(offset, animated: true)
    }

    // MARK: Modes and bridge events

    func showHints(newTab: Bool) {
        guard let webView = activeTab?.webView else { return }
        mode = .hints
        statusMessage = newTab ? "Type a label to open in a new tab" : "Type a label to click"
        Bridge.call(webView, "showHints", [newTab])
    }

    func hintKey(_ key: String) {
        guard let webView = activeTab?.webView else { return }
        Bridge.call(webView, "hintKey", [key])
    }

    func cancelHints() {
        guard let webView = activeTab?.webView else { return }
        Bridge.call(webView, "hideHints")
        if mode == .hints { mode = .normal }
        statusMessage = ""
    }

    func hintsChanged(count: Int) {
        if count == 0 {
            if mode == .hints { mode = .normal }
            if statusMessage.hasPrefix("Type a label") { statusMessage = "" }
        }
    }

    func pageFocusChanged(editable: Bool) {
        if editable {
            mode = .insert
            statusMessage = "Typing goes to the page. Esc to stop."
        } else if mode == .insert {
            mode = .normal
            statusMessage = ""
        }
    }

    func leaveInsertMode() {
        if let webView = activeTab?.webView { Bridge.call(webView, "blur") }
        mode = .normal
        statusMessage = ""
    }

    // Insert-mode relays
    func insertText(_ text: String) { if let wv = activeTab?.webView { Bridge.call(wv, "insertText", [text]) } }
    func deleteBackward() { if let wv = activeTab?.webView { Bridge.call(wv, "deleteBackward") } }
    func pressEnter(shift: Bool) { if let wv = activeTab?.webView { Bridge.call(wv, "enter", [shift]) } }
    func moveCaret(_ direction: String) { if let wv = activeTab?.webView { Bridge.call(wv, "caret", [direction]) } }
    func focusNext(reverse: Bool) { if let wv = activeTab?.webView { Bridge.call(wv, "focusNext", [reverse]) } }

    // MARK: Display lifecycle

    func displayDidConnect(screen: UIScreen) {
        let wasAttached = displayAttached
        displayScreen = screen
        displayAttached = true
        UIApplication.shared.isIdleTimerDisabled = true
        if !wasAttached { setZoom(defaultZoom()) }
        statusMessage = "Display \(Int(screen.bounds.width))x\(Int(screen.bounds.height)) @\(screen.scale)x"
    }

    func displayDidDisconnect() {
        displayAttached = false
        displayScreen = nil
        UIApplication.shared.isIdleTimerDisabled = false
        mode = .normal
        setZoom(1.0)
        statusMessage = "Display disconnected"
    }
}

// MARK: - WKNavigationDelegate

extension BrowserModel: WKNavigationDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if let url = navigationAction.request.url,
           let scheme = url.scheme?.lowercased(),
           !["http", "https", "about", "blob", "data", "javascript"].contains(scheme) {
            UIApplication.shared.open(url)
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        let nsError = error as NSError
        if nsError.code == NSURLErrorCancelled { return }
        statusMessage = "Failed: \(error.localizedDescription)"
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        webView.reload()
    }
}

// MARK: - WKUIDelegate

extension BrowserModel: WKUIDelegate {
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        // Popups and target=_blank links become tabs. WebKit loads the request into the returned view.
        let tab = newTab(configuration: configuration)
        return tab.webView
    }

    func webViewDidClose(_ webView: WKWebView) {
        if let index = tabs.firstIndex(where: { $0.webView === webView }) {
            selectTab(index)
            closeActiveTab()
        }
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        guard let presenter else { completionHandler(); return }
        let alert = UIAlertController(title: webView.url?.host, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler() })
        presenter.present(alert, animated: true)
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        guard let presenter else { completionHandler(false); return }
        let alert = UIAlertController(title: webView.url?.host, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in completionHandler(false) })
        let ok = UIAlertAction(title: "OK", style: .default) { _ in completionHandler(true) }
        alert.addAction(ok)
        alert.preferredAction = ok
        presenter.present(alert, animated: true)
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
        guard let presenter else { completionHandler(nil); return }
        let alert = UIAlertController(title: webView.url?.host, message: prompt, preferredStyle: .alert)
        alert.addTextField { $0.text = defaultText }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in completionHandler(nil) })
        alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler(alert.textFields?.first?.text) })
        presenter.present(alert, animated: true)
    }

    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                 decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        decisionHandler(.grant)
    }
}
