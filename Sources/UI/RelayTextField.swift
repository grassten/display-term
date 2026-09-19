import UIKit

/// Invisible-ish text field that is first responder in insert mode. Every keystroke is
/// forwarded to the page and the field itself stays empty.
final class RelayTextField: UITextField {
    var onInsert: ((String) -> Void)?
    var onDelete: (() -> Void)?
    var onEnter: ((Bool) -> Void)?
    var onArrow: ((String) -> Void)?
    var onTab: ((Bool) -> Void)?

    private var shiftHeld = false
    private var lastEnter: TimeInterval = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        autocorrectionType = .no
        autocapitalizationType = .none
        spellCheckingType = .no
        smartQuotesType = .no
        smartDashesType = .no
        smartInsertDeleteType = .no
        returnKeyType = .default
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func insertText(_ text: String) {
        if text == "\n" || text == "\r" {
            fireEnter()
        } else {
            onInsert?(text)
        }
    }

    override func deleteBackward() {
        onDelete?()
    }

    func fireEnter() {
        let now = Date().timeIntervalSinceReferenceDate
        guard now - lastEnter > 0.05 else { return }
        lastEnter = now
        onEnter?(shiftHeld)
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        guard let key = presses.first?.key else { return super.pressesBegan(presses, with: event) }
        shiftHeld = key.modifierFlags.contains(.shift)
        switch key.keyCode {
        case .keyboardLeftArrow: onArrow?("ArrowLeft")
        case .keyboardRightArrow: onArrow?("ArrowRight")
        case .keyboardUpArrow: onArrow?("ArrowUp")
        case .keyboardDownArrow: onArrow?("ArrowDown")
        case .keyboardTab: onTab?(shiftHeld)
        default: super.pressesBegan(presses, with: event)
        }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if let key = presses.first?.key { shiftHeld = key.modifierFlags.contains(.shift) }
        super.pressesEnded(presses, with: event)
    }
}
