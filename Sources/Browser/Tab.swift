import WebKit
import Combine

final class Tab: NSObject, ObservableObject {
    let id = UUID()
    let webView: WKWebView

    @Published private(set) var title: String = ""
    @Published private(set) var url: URL?
    @Published private(set) var progress: Double = 1
    @Published private(set) var canGoBack = false
    @Published private(set) var canGoForward = false

    private var observers: [NSKeyValueObservation] = []

    init(configuration: WKWebViewConfiguration) {
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.allowsBackForwardNavigationGestures = true
        webView.customUserAgent = BrowserModel.desktopUserAgent
        webView.backgroundColor = .white
        observers = [
            webView.observe(\.title, options: [.new]) { [weak self] wv, _ in self?.title = wv.title ?? "" },
            webView.observe(\.url, options: [.new]) { [weak self] wv, _ in self?.url = wv.url },
            webView.observe(\.estimatedProgress, options: [.new]) { [weak self] wv, _ in self?.progress = wv.estimatedProgress },
            webView.observe(\.canGoBack, options: [.new]) { [weak self] wv, _ in self?.canGoBack = wv.canGoBack },
            webView.observe(\.canGoForward, options: [.new]) { [weak self] wv, _ in self?.canGoForward = wv.canGoForward },
        ]
    }

    var displayTitle: String {
        if !title.isEmpty { return title }
        if let host = url?.host { return host }
        return "New Tab"
    }

    func load(_ url: URL) {
        webView.load(URLRequest(url: url))
    }
}
