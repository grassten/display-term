import UIKit
import SwiftTerm

protocol CommandUI: AnyObject {
    func openSettings()
    func toggleChrome()
}

/// Runs a key binding's action against the workspace and the focused pane.
final class Commands {
    unowned let state: AppState
    weak var ui: CommandUI?

    init(state: AppState) { self.state = state }

    func perform(_ binding: KeyBinding) {
        let workspace = state.workspace
        let pane = workspace.focusedPane
        let view = pane?.terminalView
        switch binding.action {
        case .newTab: workspace.newTab()
        case .closePane: workspace.closeFocusedPane()
        case .closeTab: if let tab = workspace.activeTab { workspace.closeTab(tab) }
        case .nextTab: workspace.nextTab()
        case .previousTab: workspace.previousTab()
        case .selectTab: if let n = Int(binding.arg ?? "") { workspace.selectTab(n - 1) }
        case .moveTabLeft: workspace.moveTab(by: -1)
        case .moveTabRight: workspace.moveTab(by: 1)
        case .splitVertical: workspace.split(.vertical)
        case .splitHorizontal: workspace.split(.horizontal)
        case .focusPane: if let d = Direction(rawValue: binding.arg ?? "") { workspace.focusPane(d) }
        case .nextPane: workspace.cyclePane(by: 1)
        case .previousPane: workspace.cyclePane(by: -1)
        case .toggleMaximizePane: workspace.toggleMaximize()
        case .moveDivider: if let d = Direction(rawValue: binding.arg ?? "") { workspace.moveDivider(d) }
        case .copy:
            if let text = view?.getSelection(), !text.isEmpty {
                UIPasteboard.general.string = text
                view?.selectNone()
            }
        case .paste:
            if let text = UIPasteboard.general.string, let view { Self.paste(text, into: view) }
        case .selectAll: view?.selectAll()
        case .clearBuffer: pane?.clearBuffer()
        case .resetTerminal: pane?.resetTerminal()
        case .reconnect: pane?.reconnectNow()
        case .fontBigger: adjustFont(by: 1)
        case .fontSmaller: adjustFont(by: -1)
        case .fontReset: adjustFont(by: 0)
        case .scrollLineUp: view?.scrollUp(lines: 1)
        case .scrollLineDown: view?.scrollDown(lines: 1)
        case .scrollPageUp: view?.pageUp()
        case .scrollPageDown: view?.pageDown()
        case .scrollTop: view?.scroll(toPosition: 0)
        case .scrollBottom: view?.scroll(toPosition: 1)
        case .toggleChrome: ui?.toggleChrome()
        case .openSettings: ui?.openSettings()
        case .sendText: if let text = binding.arg { view?.send(txt: text) }
        case .sendBytes: if let bytes = Self.hexBytes(binding.arg ?? "") { view?.send(bytes) }
        }
    }

    /// Paste through the view so bracketed-paste mode is honoured when the app asked for it.
    static func paste(_ text: String, into view: TerminalView) {
        UIPasteboard.general.string = text
        view.paste(nil)
    }

    private func adjustFont(by delta: CGFloat) {
        let prefs = state.preferences
        if state.displayAttached {
            prefs.displayFontSize = delta == 0 ? Preferences.defaultDisplayFontSize : max(8, min(64, prefs.displayFontSize + delta))
        } else {
            prefs.phoneFontSize = delta == 0 ? Preferences.defaultPhoneFontSize : max(8, min(32, prefs.phoneFontSize + delta))
        }
    }

    static func hexBytes(_ text: String) -> [UInt8]? {
        let clean = text.replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "0x", with: "")
        guard clean.count % 2 == 0 else { return nil }
        var bytes: [UInt8] = []
        var index = clean.startIndex
        while index < clean.endIndex {
            let next = clean.index(index, offsetBy: 2)
            guard let byte = UInt8(clean[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        return bytes
    }
}
