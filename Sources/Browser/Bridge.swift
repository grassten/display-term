import WebKit

/// Native side of `bridge.js`. Receives focus/hint events from pages and calls into them.
final class Bridge: NSObject, WKScriptMessageHandler {
    static let shared = Bridge()
    static let handlerName = "db"

    static let userScript: WKUserScript = {
        var source = ""
        if let url = Bundle.main.url(forResource: "bridge", withExtension: "js"),
           let text = try? String(contentsOf: url, encoding: .utf8) {
            source = text
        } else {
            NSLog("[Bridge] bridge.js missing from bundle")
        }
        return WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true)
    }()

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        let model = BrowserModel.shared
        guard let webView = message.webView, webView === model.activeTab?.webView else { return }

        switch type {
        case "focus":
            model.pageFocusChanged(editable: body["editable"] as? Bool ?? false)
        case "hints":
            model.hintsChanged(count: body["count"] as? Int ?? 0)
        case "openTab":
            if let s = body["url"] as? String, let url = URL(string: s) {
                model.newTab(url: url, select: false)
                model.statusMessage = "Opened in new tab: \(url.host ?? s)"
            }
        default:
            break
        }
    }

    // MARK: Calls into the page

    static func call(_ webView: WKWebView, _ function: String, _ args: [Any] = []) {
        let list = args.map(literal).joined(separator: ",")
        let js = "window.__db && window.__db.\(function)(\(list));"
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    private static func literal(_ value: Any) -> String {
        switch value {
        case let s as String:
            if let data = try? JSONSerialization.data(withJSONObject: [s]),
               let text = String(data: data, encoding: .utf8) {
                return String(text.dropFirst().dropLast())
            }
            return "\"\""
        case let b as Bool:
            return b ? "true" : "false"
        default:
            return "\(value)"
        }
    }
}
