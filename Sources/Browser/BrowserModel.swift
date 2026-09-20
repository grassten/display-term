import UIKit
import WebKit
import Combine

/// Shared state for both scenes: tabs, input mode, zoom, navigation, scrolling, pointer,
/// clipboard, find, downloads and session persistence.
final class BrowserModel: NSObject, ObservableObject {
    static let shared = BrowserModel()

    static let desktopUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15"
    static let homeURL = URL(string: "https://www.google.com/")!
    static let helpText = "f links · j/k scroll · H/L back/fwd · J/K tabs · o/⌘L url · t/⌘T new · x/⌘W close · ⌘F find · Esc"

    enum Mode: String { case normal = "NORMAL", insert = "INSERT", hints = "HINTS", find = "FIND" }

    enum ScrollAction { case line(Int), halfPage(Int), page(Int), top, bottom }

    @Published private(set) var tabs: [Tab] = []
    @Published private(set) var activeIndex: Int = 0
    @Published private(set) var displayAttached = false
    /// True while the page itself has a text field focused. Arrow keys and space scroll
    /// the page when this is false and go to the page when it is true, like any browser.
    @Published private(set) var pageEditableFocused = false
    /// While true the active page is shown on the phone instead of the display, as an
    /// ordinary first-responder web view. That is the only way to reach iCloud Keychain
    /// AutoFill: the external scene receives no input, so iOS never offers to fill there.
    @Published var handoffToPhone = false
    @Published private(set) var darkMode = true
    @Published private(set) var displayScreen: UIScreen?
    @Published var mode: Mode = .insert
    @Published private(set) var pageZoom: CGFloat = 1.0
    @Published var statusMessage: String = ""
    @Published var urlDraft: String = ""
    @Published var isEditingURL = false
    @Published private(set) var findText: String = ""
    @Published private(set) var findMatched: Bool?
    @Published private(set) var mouseCount = 0

    let pointer = PointerController()
    private var mouseInput: MouseInput?

    /// View controller used to present JavaScript alerts (always the phone, where taps work).
    weak var presenter: UIViewController?
    /// Set by the phone controller; called when the display's URL bar or "+" is clicked.
    var urlEntryRequested: (() -> Void)?
    /// Set by the display controller. Pages report these through the bridge: a right-click
    /// that the page did not swallow (with what is under the pointer), a click on a
    /// `<select>` (with its options), and the cursor shape from inside a cross-origin frame.
    var contextMenuRequested: (([String: Any]) -> Void)?
    var selectRequested: (([String: Any]) -> Void)?
    var cursorProbe: (([String: Any]) -> Void)?

    func requestURLEntry() { urlEntryRequested?() }

    private let processPool = WKProcessPool()
    private var tabSinks: [UUID: AnyCancellable] = [:]
    private var closedURLs: [URL] = []
    private var sessionSaveScheduled = false

    var activeTab: Tab? { tabs.indices.contains(activeIndex) ? tabs[activeIndex] : nil }

    /// UI scale for chrome drawn on the external display (1x on a 4K panel is unreadable).
    var displayUIScale: CGFloat {
        guard let screen = displayScreen else { return 1 }
        return screen.bounds.width >= 3000 ? 2.0 : 1.5
    }

    override init() {
        super.init()
        if PointerController.Settings.externalPointingDevices {
            mouseInput = MouseInput(pointer: pointer)
        }
        mouseInput?.onConnectionChange = { [weak self] count in
            self?.mouseCount = count
            self?.statusMessage = count > 0 ? "Pointing device connected" : "Pointing device disconnected"
        }
        // The phone's status line shows what the trackpad is actually doing, so it has to
        // repaint while it is being moved, not only when a device comes and goes.
        mouseInput?.onActivity = { [weak self] in self?.objectWillChange.send() }
        pointer.onAssistiveTouchChange = { [weak self] on in
            guard let self, self.mouseCount > 0 else { return }
            self.statusMessage = on ? "AssistiveTouch on: the trackpad is mapped to the phone's screen. Turn it off for a real pointer."
                                    : "AssistiveTouch off: the trackpad is a free pointer."
        }
        restoreSession()
    }

    // MARK: Tabs

    private func makeConfiguration() -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration()
        config.processPool = processPool
        config.allowsInlineMediaPlayback = true
        config.allowsPictureInPictureMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.defaultWebpagePreferences.preferredContentMode = .desktop
        config.preferences.isElementFullscreenEnabled = true
        // Our clicks are synthetic and carry no user activation, and WebKit's popup blocker
        // keys on exactly that. Without this, window.open() and target=_blank links from a
        // click do nothing; "Sign in with Google" is the everyday casualty. Popups become
        // tabs via createWebViewWith below.
        config.preferences.javaScriptCanOpenWindowsAutomatically = true
        Bridge.install(in: config)
        return config
    }

    @discardableResult
    func newTab(url: URL? = nil, configuration: WKWebViewConfiguration? = nil, select: Bool = true) -> Tab {
        let tab = Tab(configuration: configuration ?? makeConfiguration())
        tab.applyAppearance(dark: darkMode)
        tab.webView.navigationDelegate = self
        tab.webView.uiDelegate = self
        tabs.append(tab)
        tabSinks[tab.id] = tab.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
            self?.scheduleSessionSave()
        }
        if select { activeIndex = tabs.count - 1; mode = .insert }
        if let url { tab.load(url) }
        scheduleSessionSave()
        return tab
    }

    func closeTab(at index: Int) {
        guard tabs.indices.contains(index) else { return }
        let tab = tabs[index]
        if let url = tab.url { closedURLs.append(url) }
        tabSinks[tab.id] = nil
        tab.webView.removeFromSuperview()
        tabs.remove(at: index)
        if tabs.isEmpty {
            newTab(url: Self.homeURL)
        } else if activeIndex >= index {
            activeIndex = max(0, min(activeIndex - (activeIndex > index ? 1 : 0), tabs.count - 1))
        }
        mode = .insert
        scheduleSessionSave()
    }

    func closeActiveTab() { closeTab(at: activeIndex) }

    func reopenClosedTab() {
        guard let url = closedURLs.popLast() else { statusMessage = "No closed tabs"; return }
        newTab(url: url)
    }

    func selectTab(_ index: Int) {
        guard tabs.indices.contains(index) else { return }
        activeIndex = index
        mode = .insert
        scheduleSessionSave()
    }

    func nextTab() { guard !tabs.isEmpty else { return }; selectTab((activeIndex + 1) % tabs.count) }
    func previousTab() { guard !tabs.isEmpty else { return }; selectTab((activeIndex - 1 + tabs.count) % tabs.count) }

    // MARK: Session persistence

    private func restoreSession() {
        let defaults = UserDefaults.standard
        let saved = defaults.stringArray(forKey: "session.tabs") ?? []
        let urls = saved.compactMap { URL(string: $0) }
        if urls.isEmpty {
            newTab(url: Self.homeURL)
            return
        }
        for url in urls { newTab(url: url, select: false) }
        activeIndex = min(max(defaults.integer(forKey: "session.active"), 0), tabs.count - 1)
    }

    private func scheduleSessionSave() {
        guard !sessionSaveScheduled else { return }
        sessionSaveScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self else { return }
            self.sessionSaveScheduled = false
            let urls = self.tabs.compactMap { $0.url?.absoluteString }
            UserDefaults.standard.set(urls, forKey: "session.tabs")
            UserDefaults.standard.set(self.activeIndex, forKey: "session.active")
        }
    }

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
        mode = .insert
    }

    func goBack() { activeTab?.webView.goBack() }
    func goForward() { activeTab?.webView.goForward() }
    func reload() { activeTab?.webView.reload() }
    func stop() { activeTab?.webView.stopLoading() }

    // MARK: Zoom

    func zoom(by delta: CGFloat) { setZoom(pageZoom + delta) }
    func resetZoom() { setZoom(defaultZoom()) }

    /// Diagnostic value. WKWebView.pageZoom on this path magnifies the rendered page
    /// without shrinking its layout viewport, so anything above 1.0 pushed the page off
    /// the right and bottom edges of the panel. Readability is handled separately.
    private func defaultZoom() -> CGFloat {
        guard displayAttached, displayScreen != nil else { return 1.0 }
        return 1.5
    }

    /// The display lays the web view out at its own size divided by this and scales the
    /// result up, so the page sees a smaller CSS viewport. WKWebView.pageZoom is
    /// deliberately left at 1.0; it magnifies without reflowing.
    private func setZoom(_ value: CGFloat) {
        pageZoom = min(max(value, 0.5), 4.0)
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

    // MARK: Pointer → page (points are in CSS pixels, i.e. already divided by pageZoom)

    private func modifierDictionary(_ flags: UIKeyModifierFlags) -> [String: Bool] {
        ["shift": flags.contains(.shift), "meta": flags.contains(.command),
         "ctrl": flags.contains(.control), "alt": flags.contains(.alternate)]
    }

    func cssPoint(fromWebViewPoint p: CGPoint) -> CGPoint {
        CGPoint(x: p.x / pageZoom, y: p.y / pageZoom)
    }

    func webPointerMove(_ p: CGPoint, buttons: Int) {
        guard let wv = activeTab?.webView else { return }
        Bridge.call(wv, "pointerMove", [p.x, p.y, buttons, modifierDictionary(pointer.modifiers)])
    }

    func webPointerButton(_ button: PointerController.Button, pressed: Bool, at p: CGPoint,
                          clickCount: Int, modifiers: UIKeyModifierFlags) {
        guard let wv = activeTab?.webView else { return }
        Bridge.call(wv, pressed ? "pointerDown" : "pointerUp",
                    [p.x, p.y, button.rawValue, clickCount, modifierDictionary(modifiers)])
    }

    func webScroll(at p: CGPoint, dx: CGFloat, dy: CGFloat) {
        guard let wv = activeTab?.webView else { return }
        Bridge.call(wv, "scrollAt", [p.x, p.y, dx / pageZoom, dy / pageZoom])
    }

    func webProbe(at p: CGPoint, completion: @escaping ([String: Any]?) -> Void) {
        guard let wv = activeTab?.webView else { completion(nil); return }
        Bridge.query(wv, "probe", [p.x, p.y]) { result in completion(result as? [String: Any]) }
    }

    // MARK: Clipboard

    /// The page answers with a `clipboard` message (see `clipboardFromPage`), which lets
    /// the selection live in any frame.
    func copySelection() {
        guard let wv = activeTab?.webView else { return }
        Bridge.call(wv, "copySelection", [false])
    }

    func clipboardFromPage(text: String, cut: Bool) {
        guard !text.isEmpty else { statusMessage = "Nothing selected"; return }
        UIPasteboard.general.string = text
        statusMessage = "\(cut ? "Cut" : "Copied") \(text.count) characters"
    }

    func paste() {
        guard let text = UIPasteboard.general.string, !text.isEmpty else { statusMessage = "Clipboard is empty"; return }
        insertText(text)
    }

    func cut() {
        guard let wv = activeTab?.webView else { return }
        Bridge.call(wv, "copySelection", [true])
    }

    func selectAll() {
        guard let wv = activeTab?.webView else { return }
        Bridge.call(wv, "selectAll")
    }

    func copyToPasteboard(_ text: String, label: String) {
        UIPasteboard.general.string = text
        statusMessage = "Copied \(label)"
    }

    /// Picks an option from the `<select>` the page last reported (see `selectRequested`).
    func chooseOption(_ index: Int) {
        guard let wv = activeTab?.webView else { return }
        Bridge.call(wv, "chooseOption", [index])
    }

    // MARK: Find in page

    func enterFindMode() {
        if mode == .insert { leaveInsertMode() }
        mode = .find
        statusMessage = "Find: type, Enter for next, ⇧Enter previous, Esc to close"
    }

    func leaveFindMode() {
        if mode == .find { mode = .insert }
        findMatched = nil
        statusMessage = ""
    }

    func find(_ text: String, forward: Bool = true) {
        findText = text
        guard let wv = activeTab?.webView, !text.isEmpty else { findMatched = nil; return }
        let config = WKFindConfiguration()
        config.backwards = !forward
        config.caseSensitive = false
        config.wraps = true
        wv.find(text, configuration: config) { [weak self] result in
            self?.findMatched = result.matchFound
        }
    }

    func findNext() { find(findText, forward: true) }
    func findPrevious() { find(findText, forward: false) }

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
        if mode == .hints { mode = .insert }
        statusMessage = ""
    }

    func hintsChanged(count: Int) {
        if count == 0 {
            if mode == .hints { mode = .insert }
            if statusMessage.hasPrefix("Type a label") { statusMessage = "" }
        }
    }

    func pageFocusChanged(editable: Bool, password: Bool = false) {
        pageEditableFocused = editable
        if password, displayAttached, !handoffToPhone {
            statusMessage = "Password field: tap \"Type on phone\" to use saved passwords."
        }
    }

    /// Called when the app comes back to the foreground: GCMouse only feeds the foreground
    /// app, so a trackpad can come back silently dead otherwise.
    func reattachPointingDevices() { mouseInput?.reattachAll() }

    /// What the attached pointing device is doing, for the phone's status line.
    var pointerDiagnostics: String { mouseInput?.diagnostics ?? "trackpad off" }

    func toggleDarkMode() {
        darkMode.toggle()
        for tab in tabs { tab.applyAppearance(dark: darkMode) }
        statusMessage = darkMode ? "Dark mode on" : "Dark mode off"
    }

    /// Escape: drop focus out of whatever page field has it. Typing still goes to the
    /// page afterwards; there is no separate command mode to return to.
    func leaveInsertMode() {
        if let webView = activeTab?.webView { Bridge.call(webView, "blur") }
        pageEditableFocused = false
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
        mode = .insert
        setZoom(1.0)
        statusMessage = "Display disconnected"
    }

    // MARK: Downloads

    private var downloadsDirectory: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("Downloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func uniqueDownloadURL(for name: String) -> URL {
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var candidate = downloadsDirectory.appendingPathComponent(name)
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            let newName = ext.isEmpty ? "\(base) (\(n))" : "\(base) (\(n)).\(ext)"
            candidate = downloadsDirectory.appendingPathComponent(newName)
            n += 1
        }
        return candidate
    }
}

// MARK: - WKNavigationDelegate

extension BrowserModel: WKNavigationDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if navigationAction.shouldPerformDownload {
            decisionHandler(.download)
            return
        }
        if let url = navigationAction.request.url,
           let scheme = url.scheme?.lowercased(),
           !["http", "https", "about", "blob", "data", "javascript", "file"].contains(scheme) {
            UIApplication.shared.open(url)
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        if let http = navigationResponse.response as? HTTPURLResponse,
           let disposition = http.value(forHTTPHeaderField: "Content-Disposition"),
           disposition.lowercased().hasPrefix("attachment") {
            decisionHandler(.download)
            return
        }
        if !navigationResponse.canShowMIMEType {
            decisionHandler(.download)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = self
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = self
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

// MARK: - WKDownloadDelegate

extension BrowserModel: WKDownloadDelegate {
    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String,
                  completionHandler: @escaping (URL?) -> Void) {
        let url = uniqueDownloadURL(for: suggestedFilename)
        statusMessage = "Downloading \(url.lastPathComponent)…"
        completionHandler(url)
    }

    func downloadDidFinish(_ download: WKDownload) {
        statusMessage = "Download finished (Files app → On My iPhone → Display Browser → Downloads)"
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        statusMessage = "Download failed: \(error.localizedDescription)"
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
            closeTab(at: index)
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
