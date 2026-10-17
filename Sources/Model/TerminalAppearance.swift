import UIKit
import SwiftTerm

/// What a terminal view looks like; re-applied only when it changes.
struct TerminalAppearance: Equatable {
    var fontSize: CGFloat
    var themeName: String
    var optionAsMeta: Bool

    func apply(to view: TerminalView, themes: ThemeStore) {
        TerminalFont.set(view, size: fontSize)
        themes.theme(named: themeName).apply(to: view)
        view.optionAsMetaKey = optionAsMeta
    }
}

extension TerminalView {
    /// Arrow keys as the running program expects them (application cursor mode or not).
    func sendArrow(_ direction: Direction) {
        let code: String
        switch direction {
        case .up: code = "A"
        case .down: code = "B"
        case .right: code = "C"
        case .left: code = "D"
        }
        send(txt: (getTerminal().applicationCursor ? "\u{1b}O" : "\u{1b}[") + code)
    }
}
