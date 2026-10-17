import UIKit
import SwiftTerm

/// First responder on the phone while docked. iOS delivers hardware-keyboard input to the
/// phone scene only, so this view receives it and hands it to the focused pane's terminal
/// view on the display, which encodes it exactly as if it had been typed into it. With no
/// hardware keyboard attached, being first responder raises the on-screen keyboard.
final class KeyRelayView: UIView, UIKeyInput {
    /// The terminal that should receive what is typed.
    var target: (() -> TerminalView?)?

    override var canBecomeFirstResponder: Bool { true }
    var hasText: Bool { true }

    // UITextInputTraits: a terminal wants raw keystrokes.
    var autocorrectionType: UITextAutocorrectionType = .no
    var autocapitalizationType: UITextAutocapitalizationType = .none
    var spellCheckingType: UITextSpellCheckingType = .no
    var smartQuotesType: UITextSmartQuotesType = .no
    var smartDashesType: UITextSmartDashesType = .no
    var smartInsertDeleteType: UITextSmartInsertDeleteType = .no
    var keyboardAppearance: UIKeyboardAppearance = .dark
    var keyboardType: UIKeyboardType = .asciiCapable
    var returnKeyType: UIReturnKeyType = .default

    private var accessory: UIView?
    override var inputAccessoryView: UIView? { accessory }

    func setAccessory(_ view: UIView?) {
        accessory = view
        if isFirstResponder { reloadInputViews() }
    }

    func insertText(_ text: String) {
        target?()?.insertText(text)
    }

    func deleteBackward() {
        target?()?.deleteBackward()
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if let view = target?() { view.pressesBegan(presses, with: event) } else { super.pressesBegan(presses, with: event) }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if let view = target?() { view.pressesEnded(presses, with: event) } else { super.pressesEnded(presses, with: event) }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if let view = target?() { view.pressesCancelled(presses, with: event) } else { super.pressesCancelled(presses, with: event) }
    }
}
