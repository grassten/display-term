import Foundation
import WebKit

// Drives bridge.js the way BrowserModel/Bridge.swift do: same content world, same
// message handler name, same token substitution. See run.sh.

setbuf(stdout, nil)
let bridgePath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "../../Sources/Resources/bridge.js"
let bridgeSource = try! String(contentsOfFile: bridgePath, encoding: .utf8)
    .replacingOccurrences(of: "__DB_TOKEN__", with: "harness-token")
let world = WKContentWorld.world(name: "displaybrowser")

var bridgeMessages: [[String: Any]] = []
var harnessMessages: [String] = []
var failures = 0

final class Handler: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    var loaded = false
    func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
        if m.name == "db", let body = m.body as? [String: Any] { bridgeMessages.append(body) }
        else if m.name == "harness", let s = m.body as? String { harnessMessages.append(s) }
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { loaded = true }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { print("!!! web content process terminated") }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        print("navigation failed: \(error)")
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        print("navigation failed late: \(error)")
    }
}

let handler = Handler()
let config = WKWebViewConfiguration()
config.userContentController.addUserScript(WKUserScript(source: bridgeSource, injectionTime: .atDocumentStart,
                                                        forMainFrameOnly: false, in: world))
config.userContentController.add(handler, contentWorld: world, name: "db")
config.userContentController.add(handler, name: "harness")
config.preferences.javaScriptCanOpenWindowsAutomatically = true
let wv = WKWebView(frame: CGRect(x: 0, y: 0, width: 900, height: 700), configuration: config)
wv.navigationDelegate = handler

func spin(_ seconds: TimeInterval) {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.005)) }
}

func spin(until done: () -> Bool, timeout: TimeInterval = 2) {
    let end = Date().addingTimeInterval(timeout)
    while !done() && Date() < end { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.005)) }
}

func eval(_ js: String, in w: WKContentWorld = .page) -> Any? {
    var result: Any?
    var done = false
    wv.evaluateJavaScript(js, in: nil, in: w) { r in
        switch r {
        case .success(let v): result = v
        case .failure(let e): print("    js error: \(e.localizedDescription) in: \(js.prefix(80))")
        }
        done = true
    }
    spin(until: { done })
    return result
}

func db(_ fn: String, _ args: String) { _ = eval("window.__db.\(fn)(\(args));", in: world) }
func dbQuery(_ fn: String, _ args: String) -> [String: Any]? {
    guard let s = eval("JSON.stringify(window.__db.\(fn)(\(args)) || null);", in: world) as? String,
          let data = s.data(using: .utf8) else { return nil }
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
}

func center(_ selector: String) -> CGPoint {
    let js = "(function(){var r=document.querySelector('\(selector)').getBoundingClientRect();return [r.left+r.width/2, r.top+r.height/2];})()"
    let a = eval(js) as? [Double] ?? [0, 0]
    return CGPoint(x: a[0], y: a[1])
}

/// Viewport point inside an iframe's content box.
func inFrame(_ frameSelector: String, _ x: CGFloat, _ y: CGFloat) -> CGPoint {
    let js = "(function(){var f=document.querySelector('\(frameSelector)');var r=f.getBoundingClientRect();return [r.left+5, r.top+5];})()"
    let a = eval(js) as? [Double] ?? [0, 0]
    return CGPoint(x: CGFloat(a[0]) + x, y: CGFloat(a[1]) + y)
}

func click(_ p: CGPoint, count: Int = 1, button: Int = 0, mods: String = "{}") {
    db("pointerMove", "\(p.x),\(p.y),0,{}")
    db("pointerDown", "\(p.x),\(p.y),\(button),\(count),\(mods)")
    db("pointerUp", "\(p.x),\(p.y),\(button),\(count),\(mods)")
}

func log() -> [String] { (eval("window.__log") as? [String]) ?? [] }
func clearLog() { _ = eval("window.__log = []") }
func selection() -> String { (eval("String(window.getSelection())") as? String) ?? "" }
func messages(_ type: String) -> [[String: Any]] { bridgeMessages.filter { $0["type"] as? String == type } }

func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
    if ok { print("PASS \(name)") } else { failures += 1; print("FAIL \(name)  \(detail())") }
}

// ------------------------------------------------------------------ run

wv.load(URLRequest(url: URL(string: "http://127.0.0.1:8801/top.html")!))
spin(until: { handler.loaded }, timeout: 8)
spin(until: { (eval("document.querySelectorAll('iframe').length === 2 && document.readyState === 'complete'") as? Bool) == true }, timeout: 5)
spin(0.6)
check("page loaded", handler.loaded)
check("bridge present in top", (eval("typeof window.__db", in: world) as? String) == "object")
check("bridge hidden from page", (eval("typeof window.__db") as? String) == "undefined")

// Hover
let btn = center("#btn")
db("pointerMove", "\(btn.x),\(btn.y),0,{}")
check("hover fires mouseover", log().contains("over btn"), "\(log())")

// Single click on a button: click, no selection, no dblclick
clearLog()
click(btn)
check("button click", log().contains("click btn detail=1 trusted=false"), "\(log())")
check("button click leaves no selection", selection().isEmpty, selection())
check("button click does not touch selection", !log().contains("selectionchange"), "\(log())")

// Double click on a button: two clicks + dblclick, still no selection
clearLog()
click(btn, count: 1); click(btn, count: 2)
check("double click on button", log().contains("dblclick btn") && log().contains("click btn detail=2 trusted=false"), "\(log())")
check("double click on button selects nothing", selection().isEmpty, selection())

// Plain click on text: click event, no selection created
let para = center("#para")
clearLog()
click(para)
check("text click", log().contains("click para detail=1"), "\(log())")
check("text click makes no selection", selection().isEmpty && !log().contains("selectionchange"), "\(log())")

// Drag across text selects and does not click
clearLog()
let paraLeft = CGPoint(x: para.x - 150, y: para.y)
db("pointerMove", "\(paraLeft.x),\(paraLeft.y),0,{}")
db("pointerDown", "\(paraLeft.x),\(paraLeft.y),0,1,{}")
for i in 1...6 { let x = paraLeft.x + CGFloat(i) * 30; db("pointerMove", "\(x),\(para.y),1,{}") }
db("pointerUp", "\(paraLeft.x + 180),\(para.y),0,1,{}")
check("drag selects text", selection().count > 5, selection())
check("drag does not click", !log().contains("click para detail=1"), "\(log())")

// Double click on text selects a word
click(para, count: 1); click(para, count: 2)
let word = selection().trimmingCharacters(in: .whitespaces)
check("double click selects a word", !word.isEmpty && !word.contains(" "), "'\(word)'")
click(btn) // buttons are not selectable, so a click on one keeps the selection (as in Safari/Chrome)
check("click on a button keeps selection", !selection().isEmpty, selection())
click(CGPoint(x: para.x + 150, y: para.y))
check("click on text clears selection", selection().isEmpty, selection())

// Link: click, and command-click opens a tab
clearLog()
let link = center("#link")
click(link)
check("link click", log().contains("click link meta=false"), "\(log())")
click(link, mods: "{meta:true}")
check("command-click posts openTab", messages("openTab").contains { ($0["url"] as? String)?.hasSuffix("#linked") == true }, "\(messages("openTab"))")

// Shadow DOM
clearLog()
click(center("#shadowhost"))
check("shadow DOM button click", log().contains("click shadow inner"), "\(log())")

// <select>
clearLog()
bridgeMessages.removeAll()
click(center("#sel"))
spin(until: { !messages("select").isEmpty })
let sel = messages("select").first
let options = sel?["options"] as? [[String: Any]] ?? []
check("select posts options", options.count == 4 && (options[1]["selected"] as? Bool) == true && (options[2]["disabled"] as? Bool) == true, "\(String(describing: sel))")
db("chooseOption", "3")
check("chooseOption fires change", log().contains("change sel=Four"), "\(log())")
_ = eval("document.activeElement.blur()")

// Same-origin iframe
harnessMessages.removeAll()
click(inFrame("#same", 50, 15))
spin(until: { !harnessMessages.isEmpty })
check("same-origin iframe click", harnessMessages.contains("same: click cbtn detail=1"), "\(harnessMessages)")

// Cross-origin iframe: click, focus, typing
harnessMessages.removeAll(); bridgeMessages.removeAll()
click(inFrame("#cross", 50, 15))
spin(until: { !harnessMessages.isEmpty })
check("cross-origin iframe click", harnessMessages.contains("cross: click cbtn detail=1"), "\(harnessMessages)")
harnessMessages.removeAll(); bridgeMessages.removeAll()
click(inFrame("#cross", 195, 15))
spin(until: { harnessMessages.contains("cross: focus cinp") })
check("cross-origin input focus", harnessMessages.contains("cross: focus cinp"), "\(harnessMessages)")
spin(0.1)
let focusMsgs = messages("focus")
check("focus message from frame says editable", (focusMsgs.last?["editable"] as? Bool) == true, "\(focusMsgs)")
check("top activeElement is the frame", (eval("document.activeElement && document.activeElement.id") as? String) == "cross")
db("insertText", "\"hi\"")
spin(until: { harnessMessages.contains("cross: input cinp=hi") })
check("typing routed into cross-origin frame", harnessMessages.contains("cross: input cinp=hi"), "\(harnessMessages)")
bridgeMessages.removeAll()
db("blur", "")
spin(until: { !messages("focus").isEmpty })
check("blur in frame reports not editable", (messages("focus").last?["editable"] as? Bool) == false, "\(messages("focus"))")

// Probe over cross-origin frame content with cursor: help
bridgeMessages.removeAll()
let cpara = inFrame("#cross", 150, 115)
db("pointerMove", "\(cpara.x),\(cpara.y),0,{}")
let probe = dbQuery("probe", "\(cpara.x),\(cpara.y)")
check("probe over cross-origin frame defers", (probe?["frame"] as? Bool) == true, "\(String(describing: probe))")
spin(until: { !messages("probe").isEmpty })
let probeInfo = messages("probe").first?["info"] as? [String: Any]
check("frame reports its cursor", (probeInfo?["cursor"] as? String) == "help", "\(String(describing: probeInfo))")

// Probe in top: link => pointer, text => text, button => pointer
check("probe link cursor", (dbQuery("probe", "\(link.x),\(link.y)")?["cursor"] as? String) == "pointer")
check("probe text cursor", (dbQuery("probe", "\(para.x),\(para.y)")?["cursor"] as? String) == "text")
check("probe button cursor", (dbQuery("probe", "\(btn.x),\(btn.y)")?["cursor"] as? String) == "pointer")

// Right click: contextmenu event in page + message with link info
clearLog(); bridgeMessages.removeAll()
click(link, button: 2)
spin(until: { !messages("contextmenu").isEmpty })
let cm = messages("contextmenu").first?["info"] as? [String: Any]
check("right click fires contextmenu", log().contains("contextmenu link"), "\(log())")
check("contextmenu message carries href", (cm?["href"] as? String)?.hasSuffix("#linked") == true, "\(String(describing: cm))")
harnessMessages.removeAll(); bridgeMessages.removeAll()
click(inFrame("#cross", 50, 60), button: 2)
spin(until: { !messages("contextmenu").isEmpty })
let cm2 = messages("contextmenu").first?["info"] as? [String: Any]
check("right click inside cross-origin frame", (cm2?["href"] as? String) == "https://example.com/child", "\(String(describing: cm2)) \(harnessMessages)")

// Clipboard from a frame selection
harnessMessages.removeAll(); bridgeMessages.removeAll()
let cparaLeft = inFrame("#cross", 5, 115)
db("pointerDown", "\(cparaLeft.x),\(cparaLeft.y),0,1,{}")
for i in 1...5 { db("pointerMove", "\(cparaLeft.x + CGFloat(i) * 20),\(cparaLeft.y),1,{}") }
db("pointerUp", "\(cparaLeft.x + 100),\(cparaLeft.y),0,1,{}")
db("copySelection", "false")
spin(until: { !messages("clipboard").isEmpty })
check("copy from cross-origin frame selection", ((messages("clipboard").first?["text"] as? String) ?? "").count > 3, "\(messages("clipboard"))")

// Scrolling: over text scrolls the document; over an unscrollable frame chains to the parent
_ = eval("window.scrollTo(0,0)")
db("scrollAt", "\(para.x),\(para.y),0,300")
spin(0.05)
check("scroll over text scrolls document", (eval("window.scrollY") as? Double) == 300, "\(String(describing: eval("window.scrollY")))")
let crossPt = inFrame("#cross", 200, 75)
db("scrollAt", "\(crossPt.x),\(crossPt.y),0,300")
spin(until: { (eval("window.scrollY") as? Double) == 600 })
check("scroll over unscrollable frame chains to parent", (eval("window.scrollY") as? Double) == 600, "\(String(describing: eval("window.scrollY")))")

// Input focus in top and blur
clearLog(); bridgeMessages.removeAll()
_ = eval("window.scrollTo(0,0)")
click(center("#inp"))
spin(until: { !messages("focus").isEmpty })
check("input click focuses (editable)", (messages("focus").last?["editable"] as? Bool) == true, "\(messages("focus"))")
db("insertText", "\"ab\"")
check("typing into top input", log().contains("input inp=ab"), "\(log())")
bridgeMessages.removeAll()
click(para)
spin(until: { !messages("focus").isEmpty })
check("click on text blurs input", (messages("focus").last?["editable"] as? Bool) == false, "\(messages("focus"))")

print(failures == 0 ? "\nALL PASS" : "\n\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
