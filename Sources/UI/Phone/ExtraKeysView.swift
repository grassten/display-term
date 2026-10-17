import UIKit
import SwiftTerm

/// The row of keys a terminal needs that the iOS keyboard lacks. Sits above the on-screen
/// keyboard, and at the bottom of the docked layout.
final class ExtraKeysView: UIView {
    var target: (() -> TerminalView?)?
    var menuProvider: (() -> UIMenu)?

    private let stack = UIStackView()
    private var ctrlButton: UIButton!
    private var altButton: UIButton!

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor(white: 0.11, alpha: 1)
        stack.axis = .horizontal
        stack.spacing = 5
        stack.distribution = .fillProportionally
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            stack.heightAnchor.constraint(equalToConstant: 34),
        ])
        add("esc") { $0.send([0x1b]) }
        add("tab") { $0.send([0x09]) }
        ctrlButton = add("ctrl") { [weak self] view in
            view.controlModifier.toggle()
            self?.syncModifiers()
        }
        altButton = add("alt") { [weak self] view in
            view.metaModifier.toggle()
            self?.syncModifiers()
        }
        add("↑") { $0.sendArrow(.up) }
        add("↓") { $0.sendArrow(.down) }
        add("←") { $0.sendArrow(.left) }
        add("→") { $0.sendArrow(.right) }
        add("-") { $0.send(txt: "-") }
        add("|") { $0.send(txt: "|") }
        let menuButton = makeButton("⌘ ⋯")
        menuButton.showsMenuAsPrimaryAction = true
        menuButton.menu = UIMenu(children: [UIDeferredMenuElement.uncached { [weak self] completion in
            completion(self?.menuProvider?().children ?? [])
        }])
        stack.addArrangedSubview(menuButton)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var intrinsicContentSize: CGSize { CGSize(width: UIView.noIntrinsicMetric, height: 44) }

    @discardableResult
    private func add(_ title: String, _ action: @escaping (TerminalView) -> Void) -> UIButton {
        let button = makeButton(title)
        button.addAction(UIAction { [weak self] _ in
            guard let view = self?.target?() else { return }
            action(view)
            self?.syncModifiers()
        }, for: .touchUpInside)
        stack.addArrangedSubview(button)
        return button
    }

    private func makeButton(_ title: String) -> UIButton {
        var config = UIButton.Configuration.filled()
        config.title = title
        config.baseBackgroundColor = UIColor(white: 0.23, alpha: 1)
        config.baseForegroundColor = .white
        config.cornerStyle = .medium
        config.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 6, bottom: 6, trailing: 6)
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attrs in
            var a = attrs
            a.font = UIFont.monospacedSystemFont(ofSize: 13, weight: .medium)
            return a
        }
        let button = UIButton(configuration: config)
        button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return button
    }

    /// Sticky modifiers show as highlighted until the next key consumes them.
    func syncModifiers() {
        let view = target?()
        ctrlButton.configuration?.baseBackgroundColor = view?.controlModifier == true ? .systemBlue : UIColor(white: 0.23, alpha: 1)
        altButton.configuration?.baseBackgroundColor = view?.metaModifier == true ? .systemBlue : UIColor(white: 0.23, alpha: 1)
    }
}
