import UIKit

/// A right-click menu drawn on the external display and operated with the virtual cursor.
final class ContextMenuView: UIView {
    struct Item {
        let title: String
        let action: () -> Void
    }

    private let items: [Item]
    private let stack = UIStackView()
    var onDismiss: (() -> Void)?

    init(items: [Item], scale: CGFloat) {
        self.items = items
        super.init(frame: .zero)
        backgroundColor = UIColor(white: 0.16, alpha: 0.98)
        layer.cornerRadius = 8 * scale
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.5
        layer.shadowRadius = 8 * scale
        layer.shadowOffset = CGSize(width: 0, height: 2 * scale)

        stack.axis = .vertical
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        let pad = 4 * scale
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: pad),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -pad),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: pad),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -pad),
        ])

        for (index, item) in items.enumerated() {
            let button = UIButton(type: .custom)
            button.tag = index
            button.setTitle(item.title, for: .normal)
            button.setTitleColor(.white, for: .normal)
            button.setBackgroundImage(Self.solidImage(.systemBlue), for: .highlighted)
            button.titleLabel?.font = .systemFont(ofSize: 13 * scale)
            button.contentHorizontalAlignment = .left
            button.contentEdgeInsets = UIEdgeInsets(top: 0, left: 12 * scale, bottom: 0, right: 12 * scale)
            button.layer.cornerRadius = 5 * scale
            button.clipsToBounds = true
            button.heightAnchor.constraint(equalToConstant: 26 * scale).isActive = true
            button.widthAnchor.constraint(greaterThanOrEqualToConstant: 220 * scale).isActive = true
            button.addTarget(self, action: #selector(itemTapped(_:)), for: .touchUpInside)
            stack.addArrangedSubview(button)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func itemTapped(_ sender: UIButton) {
        let item = items[sender.tag]
        onDismiss?()
        item.action()
    }

    private static func solidImage(_ color: UIColor) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1))
        return renderer.image { ctx in
            color.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        }
    }
}
