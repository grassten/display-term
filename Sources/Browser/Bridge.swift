import WebKit

/// Native side of `bridge.js`. Receives focus/hint/pointer events from pages and calls
/// into them. The script runs in every frame, in a content world of its own so page
/// scripts see neither `window.__db` nor the frame-forwarding token.
final class Bridge: NSObject, WKScriptMessageHandler {
    static let shared = Bridge()
    static let handlerName = "db"
    static let world = WKContentWorld.world(name: "displaybrowser")

    /// Random per launch. Frames forward pointer input to each other by postMessage and
    /// accept it only with this token, so a page cannot forge clicks into a cross-origin
    /// frame it embeds.
    static let token = UUID().uuidString

    static let userScript: WKUserScript = {
        var source = ""
        if let url = Bundle.main.url(forResource: "bridge", withExtension: "js"),
           let text = try? String(contentsOf: url, encoding: .utf8) {
            source = text.replacingOccurrences(of: "__DB_TOKEN__", with: token)
        } else {
            NSLog("[Bridge] bridge.js missing from bundle")
        }
        return WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: world)
    }()

    static func install(in configuration: WKWebViewConfiguration) {
        configuration.userContentController.addUserScript(userScript)
        configuration.userContentController.add(shared, contentWorld: world, name: handlerName)
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        let model = BrowserModel.shared
        guard let webView = message.webView, webView === model.activeTab?.webView else { return }

        switch type {
        case "debug":
            NSLog("[Bridge] \(body["info"] as? String ?? "?")")
        case "focus":
            model.pageFocusChanged(editable: body["editable"] as? Bool ?? false,
                                   password: body["password"] as? Bool ?? false)
        case "hints":
            model.hintsChanged(count: body["count"] as? Int ?? 0)
        case "openTab":
            if let s = body["url"] as? String, let url = URL(string: s) {
                model.newTab(url: url, select: false)
                model.statusMessage = "Opened in new tab: \(url.host ?? s)"
            }
        case "probe":
            // Cursor shape reported by a cross-origin frame the pointer is over.
            if let info = body["info"] as? [String: Any] { model.cursorProbe?(info) }
        case "contextmenu":
            model.contextMenuRequested?((body["info"] as? [String: Any]) ?? [:])
        case "select":
            model.selectRequested?(body)
        case "clipboard":
            model.clipboardFromPage(text: body["text"] as? String ?? "", cut: body["cut"] as? Bool ?? false)
        case "status":
            if let text = body["text"] as? String { model.statusMessage = text }
        default:
            break
        }
    }

    // MARK: Calls into the page

    static func call(_ webView: WKWebView, _ function: String, _ args: [Any] = []) {
        let list = args.map(literal).joined(separator: ",")
        let js = "window.__db && window.__db.\(function)(\(list));"
        webView.evaluateJavaScript(js, in: nil, in: world) { _ in }
    }

    /// Calls a function and returns its result (JSON-serialised on the JS side).
    static func query(_ webView: WKWebView, _ function: String, _ args: [Any] = [],
                      completion: @escaping (Any?) -> Void) {
        let list = args.map(literal).joined(separator: ",")
        let js = "(function(){ if (!window.__db) return null; var r = window.__db.\(function)(\(list)); return r === undefined ? null : JSON.stringify(r); })();"
        webView.evaluateJavaScript(js, in: nil, in: world) { result in
            guard case .success(let value) = result, let text = value as? String,
                  let data = text.data(using: .utf8) else { completion(nil); return }
            completion(try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]))
        }
    }

    static func literal(_ value: Any) -> String {
        // Check Bool by exact type first: on Darwin, `(1 as Any) as? Bool` can succeed via
        // NSNumber bridging, which would turn button/click counts into true/false.
        if type(of: value) == Bool.self, let b = value as? Bool {
            return b ? "true" : "false"
        }
        if let n = value as? NSNumber {
            let d = n.doubleValue
            return d.isFinite ? "\(d)" : "0"
        }
        if let s = value as? String {
            if let data = try? JSONSerialization.data(withJSONObject: [s]),
               let text = String(data: data, encoding: .utf8) {
                return String(text.dropFirst().dropLast())
            }
            return "\"\""
        }
        if JSONSerialization.isValidJSONObject(value),
           let data = try? JSONSerialization.data(withJSONObject: value),
           let text = String(data: data, encoding: .utf8) {
            return text
        }
        return "null"
    }
}
